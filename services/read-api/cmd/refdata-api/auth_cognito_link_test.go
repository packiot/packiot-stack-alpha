// auth_cognito_link_test.go — ADR-0034 link-on-login self-heal.
//
// Proves firebaseBearerAuth.resolve binds users.id_user_cognito on an existing
// user's FIRST Cognito login (verified sub unmatched → matched by the token's
// VERIFIED email), then resolves the tenant — and that the mechanism is a strict
// NO-OP for Firebase tokens, unverified emails, unknown emails, and a second
// (already-linked) call. Tokens are REAL RS256, verified by the actual
// cognitoVerifier/firebaseVerifier (preloaded keys) — the email/sub the link
// consumes always comes off a signature-verified payload.
package main

import (
	"context"
	"strings"
	"testing"
	"time"
)

// fakeUser is one row of the in-memory users table the link test resolves
// against. It mirrors the columns linkCognitoSQL + usersEnterpriseSQL touch.
type fakeUser struct {
	enterprise  int
	cognitoSub  string // users.id_user_cognito ("" = NULL, i.e. unlinked)
	firebaseUID string // users.id_user_firebase
	active      bool
}

// fakeUsers models the users table with just enough behavior to exercise the
// link path: an email-keyed store whose lookup/link closures reproduce
// usersEnterpriseSQL (match sub on EITHER id column) and linkCognitoSQL (bind
// the cognito sub by email, idempotent on the IS-NULL guard).
type fakeUsers struct {
	rows  []*fakeUser
	email map[string]*fakeUser // lower(email) → row
	links int                  // count of UPDATEs that actually bound a row
}

func newFakeUsers() *fakeUsers {
	return &fakeUsers{email: map[string]*fakeUser{}}
}

func (f *fakeUsers) add(email string, u *fakeUser) *fakeUser {
	f.rows = append(f.rows, u)
	f.email[strings.ToLower(email)] = u
	return u
}

// lookup reproduces usersEnterpriseSQL: a verified subject resolves iff some
// ACTIVE row carries it in id_user_firebase OR id_user_cognito and has a tenant.
func (f *fakeUsers) lookup(_ context.Context, uid string) (resolvedIdentity, error) {
	for _, u := range f.rows {
		if u.active && u.enterprise != 0 && (u.cognitoSub == uid || u.firebaseUID == uid) {
			return resolvedIdentity{customerID: u.enterprise}, nil
		}
	}
	return resolvedIdentity{}, errUnknownUID
}

// link reproduces linkCognitoSQL: bind the sub to the ACTIVE row matching the
// (already-lowercased) email, but only when id_user_cognito IS NULL — so a
// second call is a no-op (0 rows), exactly like the IS-NULL guard + partial
// unique index in prod.
func (f *fakeUsers) link(_ context.Context, sub, email string) error {
	u := f.email[strings.ToLower(email)]
	if u != nil && u.active && u.cognitoSub == "" {
		u.cognitoSub = sub
		f.links++
	}
	return nil
}

func newLinkAuth(v verifier, u *fakeUsers) *firebaseBearerAuth {
	return &firebaseBearerAuth{
		verify: v,
		lookup: u.lookup,
		link:   u.link,
		ttl:    time.Minute,
		cache:  map[string]cacheEntry{},
	}
}

func TestCognitoLinkOnLogin(t *testing.T) {
	ctx := context.Background()
	key, _ := genKeyCert(t)
	cog := cognitoVerifierWithKey(&key.PublicKey)

	// mint a real, signed Cognito ID token with the given sub + email claims.
	mint := func(sub, email string, verified bool) string {
		c := cognitoIDClaims()
		c["sub"] = sub
		c["email"] = email
		c["email_verified"] = verified
		return mintRS256(t, key, testKID, c)
	}

	t.Run("unmatched sub + verified email → links + resolves tenant", func(t *testing.T) {
		u := newFakeUsers()
		row := u.add("Alice@Packiot.com", &fakeUser{enterprise: 42, firebaseUID: "fb-alice", active: true})
		a := newLinkAuth(cog, u)

		// Case-insensitive email match (token upper vs. stored mixed case).
		id, err := a.resolve(ctx, mint("cog-alice", "ALICE@packiot.com", true))
		if err != nil || id.customerID != 42 {
			t.Fatalf("resolve: id=%+v err=%v; want {customerID:42}, nil", id, err)
		}
		if row.cognitoSub != "cog-alice" {
			t.Fatalf("id_user_cognito=%q; want it bound to the verified sub", row.cognitoSub)
		}
		if u.links != 1 {
			t.Fatalf("links=%d; want exactly 1 binding UPDATE", u.links)
		}
	})

	t.Run("idempotent: second login is a no-op, still resolves", func(t *testing.T) {
		u := newFakeUsers()
		u.add("bob@packiot.com", &fakeUser{enterprise: 7, active: true})
		a := newLinkAuth(cog, u)

		if _, err := a.resolve(ctx, mint("cog-bob", "bob@packiot.com", true)); err != nil {
			t.Fatalf("first login: %v", err)
		}
		// Fresh auth (no positive cache) so the second login re-runs lookup+link.
		a2 := newLinkAuth(cog, u)
		id, err := a2.resolve(ctx, mint("cog-bob", "bob@packiot.com", true))
		if err != nil || id.customerID != 7 {
			t.Fatalf("second login: id=%+v err=%v; want {7}, nil", id, err)
		}
		if u.links != 1 {
			t.Fatalf("links=%d after two logins; want 1 (IS-NULL guard makes the 2nd a no-op)", u.links)
		}
	})

	t.Run("no email match → 401, nothing linked", func(t *testing.T) {
		u := newFakeUsers()
		u.add("alice@packiot.com", &fakeUser{enterprise: 42, active: true})
		a := newLinkAuth(cog, u)

		_, err := a.resolve(ctx, mint("cog-ghost", "nobody@packiot.com", true))
		if err != errUnknownUID {
			t.Fatalf("got err=%v; want errUnknownUID (genuinely unknown user)", err)
		}
		if u.links != 0 {
			t.Fatalf("links=%d; want 0 (no email matched)", u.links)
		}
	})

	t.Run("unverified email → never linked, 401", func(t *testing.T) {
		u := newFakeUsers()
		row := u.add("alice@packiot.com", &fakeUser{enterprise: 42, active: true})
		a := newLinkAuth(cog, u)

		_, err := a.resolve(ctx, mint("cog-imposter", "alice@packiot.com", false))
		if err != errUnknownUID {
			t.Fatalf("got err=%v; want errUnknownUID (email_verified=false is untrusted)", err)
		}
		if row.cognitoSub != "" || u.links != 0 {
			t.Fatalf("row linked on an UNVERIFIED email (sub=%q links=%d) — account-takeover hole", row.cognitoSub, u.links)
		}
	})

	t.Run("already-known Cognito user resolves without touching the link path", func(t *testing.T) {
		u := newFakeUsers()
		u.add("carol@packiot.com", &fakeUser{enterprise: 9, cognitoSub: "cog-carol", active: true})
		a := newLinkAuth(cog, u)

		id, err := a.resolve(ctx, mint("cog-carol", "carol@packiot.com", true))
		if err != nil || id.customerID != 9 {
			t.Fatalf("resolve: id=%+v err=%v; want {9}, nil", id, err)
		}
		if u.links != 0 {
			t.Fatalf("links=%d; want 0 (uid already resolved, self-heal must not run)", u.links)
		}
	})

	t.Run("self-heal disabled (nil link) → unknown sub stays 401", func(t *testing.T) {
		u := newFakeUsers()
		u.add("alice@packiot.com", &fakeUser{enterprise: 42, active: true})
		a := newLinkAuth(cog, u)
		a.link = nil // Firebase-only deployment: no link closure

		if _, err := a.resolve(ctx, mint("cog-alice", "alice@packiot.com", true)); err != errUnknownUID {
			t.Fatalf("got err=%v; want errUnknownUID (link disabled)", err)
		}
	})
}

// TestCognitoLinkIsNoOpForFirebase proves the self-heal never fires for a
// Firebase identity: routed through the real dual-accept multiVerifier, a
// verified Firebase token whose uid is unknown returns 401 with the link path
// untouched (idp="firebase", no email) — the Firebase relying-party path is
// byte-for-byte unchanged.
func TestCognitoLinkIsNoOpForFirebase(t *testing.T) {
	ctx := context.Background()

	fbKey, _ := genKeyCert(t)
	fb := verifierWithKey(&fbKey.PublicKey)
	cogKey, _ := genKeyCert(t)
	cog := cognitoVerifierWithKey(&cogKey.PublicKey)

	mv := newMultiVerifier(
		namedVerifier{idp: "firebase", iss: testIss, v: fb},
		namedVerifier{idp: "cognito", iss: testCognitoIss, v: cog},
	)

	u := newFakeUsers()
	// An email row exists that a MIS-firing link would wrongly grab.
	row := u.add("dave@packiot.com", &fakeUser{enterprise: 5, active: true})
	a := newLinkAuth(mv, u)

	// A valid Firebase token (email claim present but IRRELEVANT for Firebase)
	// whose uid maps to no user.
	c := goodClaims()
	c["sub"] = "fb-unknown"
	c["email"] = "dave@packiot.com"
	tok := mintRS256(t, fbKey, testKID, c)

	if _, err := a.resolve(ctx, tok); err != errUnknownUID {
		t.Fatalf("got err=%v; want errUnknownUID (Firebase never links)", err)
	}
	if row.cognitoSub != "" || u.links != 0 {
		t.Fatalf("Firebase token triggered a Cognito link (sub=%q links=%d) — must never happen", row.cognitoSub, u.links)
	}
}

// TestMultiVerifierVerifyClaims proves the claims seam the self-heal relies on:
// a Cognito token yields idp="cognito" + the verified lowercased email; a
// Firebase token yields idp="firebase" with NO email (so it can never be a link
// candidate).
func TestMultiVerifierVerifyClaims(t *testing.T) {
	ctx := context.Background()

	fbKey, _ := genKeyCert(t)
	fb := verifierWithKey(&fbKey.PublicKey)
	cogKey, _ := genKeyCert(t)
	cog := cognitoVerifierWithKey(&cogKey.PublicKey)

	mv := newMultiVerifier(
		namedVerifier{idp: "firebase", iss: testIss, v: fb},
		namedVerifier{idp: "cognito", iss: testCognitoIss, v: cog},
	)

	t.Run("cognito → idp + verified lowercased email", func(t *testing.T) {
		c := cognitoIDClaims()
		c["sub"] = "cog-1"
		c["email"] = "MixedCase@Packiot.com"
		c["email_verified"] = true
		got, err := mv.VerifyClaims(ctx, mintRS256(t, cogKey, testKID, c))
		if err != nil {
			t.Fatalf("VerifyClaims: %v", err)
		}
		if got.uid != "cog-1" || got.idp != "cognito" || got.email != "mixedcase@packiot.com" || !got.emailVerified {
			t.Fatalf("got %+v; want {cog-1, mixedcase@packiot.com, verified, cognito}", got)
		}
	})

	t.Run("firebase → idp=firebase, no email", func(t *testing.T) {
		c := goodClaims()
		c["sub"] = "fb-1"
		c["email"] = "someone@packiot.com" // present but must be ignored
		got, err := mv.VerifyClaims(ctx, mintRS256(t, fbKey, testKID, c))
		if err != nil {
			t.Fatalf("VerifyClaims: %v", err)
		}
		if got.uid != "fb-1" || got.idp != "firebase" || got.email != "" || got.emailVerified {
			t.Fatalf("got %+v; want {fb-1, no-email, firebase}", got)
		}
	})
}
