# Staging Firebase project — setup guide (`packiot-staging`)

> **⚠️ HISTORICAL — superseded by [ADR-0034](../adr/0034-adopt-cognito-amplify-auth.md).** The USER chose to consolidate auth onto AWS Cognito (via Amplify Auth), replacing Firebase. The manual GCP-console project-creation this guide describes is exactly the friction ADR-0034 removes: the staging identity plane becomes a Terraform `aws_cognito_user_pool` in `api-terraform`, provisioned by the same AWS creds as the rest of the stack — no GCP console, no hand-placed service-account key. Keep this guide only as the record of the Firebase path being retired.

**Status:** action guide for the USER (HISTORICAL — see ADR-0034) · **Date:** 2026-07-21 · **Relates to:** [ADR-0033](../adr/0033-unified-firebase-jwt-auth.md) (Decision 6 — separate Firebase project per environment; Decision 7 — CS-Admin owns client-user creation)

> **Why this exists.** Today staging and prod share ONE Firebase project, `fbpackiot`. That is the anti-pattern ADR-0033 Decision 6 fixes: a staging mistake (a bad auth rule, a spammed test user, a deleted account) can corrupt the **prod** user pool, and a staging ID token is `aud`-valid against the prod verifier. This guide walks the USER through standing up a dedicated **`packiot-staging`** Firebase project so staging front4 (and later operator/edge-api) authenticate against their own isolated project.
>
> **Everything below is a USER console action.** It was NOT run by any tooling. The repo prep (front4 env plumbing) is already merged/queued; this guide is the piece only the USER can do (project creation + secret handling).

---

## 0. Hard boundary — do NOT touch prod

- **Never** modify, re-key, or delete anything in the **prod** project `fbpackiot`.
- The old prod service-account key (`back4-api/private-key.json`) is **dead** (the credential was deleted in GCP). Do not resurrect it, and do not copy it anywhere. A fresh, **staging-only** service-account key is created in step 4 below.
- All steps here create a **new, separate** project. Nothing here writes to `fbpackiot`.

---

## 1. Create the project

Firebase console → **Add project**:

1. Project name: `packiot-staging` (the resulting project **ID** may get a suffix like `packiot-staging-4d1a2` if the bare name is taken — that's fine; whatever the console assigns is your `projectId`, note it down).
2. **Google Analytics: OFF** — not needed for staging auth, keep it lean.
3. Create. Wait for provisioning.

> Firebase projects are **free** to create and there is no per-project charge; each project has its own free-tier quota (see §7).

---

## 2. Enable Email/Password authentication

Console → **Build → Authentication → Get started** → **Sign-in method** tab:

1. Enable **Email/Password** (the top provider). Leave "Email link (passwordless)" OFF unless you specifically want it.
2. That's the only provider staging front4 needs today — front4 signs in with `signInWithEmailAndPassword` (see `front4/src/Context/AuthContext.jsx`).

> **Do NOT enable / upgrade to Identity Platform (GCIP).** Packiot resolves tenancy by a **DB lookup** (`users.id_user_firebase → id_enterprise`, per ADR-0033 Decision 1), NOT a Firebase custom claim, so you do not need Identity Platform's multi-tenancy or custom-claim tooling. Standard Firebase Auth (Email/Password) is **free** and sufficient. Upgrading to Identity Platform would add per-MAU billing for zero benefit here.

---

## 3. Register a Web App → copy the config → hand it to front4

Console → **Project settings (gear)** → **General** → scroll to **Your apps** → **Add app → Web (`</>`)**:

1. App nickname: `front4-staging`. **Do NOT** check "Firebase Hosting" (front4 deploys via Amplify).
2. Register. The console shows a `firebaseConfig` object — **copy all six values**:

   ```js
   const firebaseConfig = {
     apiKey:            "AIza...",              // → VITE_FIREBASE_API_KEY
     authDomain:        "packiot-staging.firebaseapp.com",       // → VITE_FIREBASE_AUTH_DOMAIN
     databaseURL:       "https://packiot-staging.firebaseio.com", // → VITE_FIREBASE_DATABASE_URL (may be absent; see note)
     projectId:         "packiot-staging",      // → VITE_FIREBASE_PROJECT_ID
     storageBucket:     "packiot-staging.appspot.com",           // → VITE_FIREBASE_STORAGE_BUCKET
     messagingSenderId: "1234567890"            // → VITE_FIREBASE_MESSAGING_SENDER_ID
   };
   ```

   > The web **apiKey is a PUBLIC identifier** — it ships inside the front4 JS bundle and is not a secret. It is safe to commit to `.env.staging`. (Firebase security comes from Auth rules + the ID-token signature, not from hiding this key.)
   >
   > Newer Firebase web configs sometimes omit `databaseURL` (only present if Realtime Database is used). Packiot only uses Auth, so if the console doesn't show a `databaseURL`, set `VITE_FIREBASE_DATABASE_URL=https://<projectId>.firebaseio.com` for parity — it is harmless and unused.

3. Paste the six values into **`front4/.env.staging`** (the keys already exist there pointing at `fbpackiot` — replace the values):

   ```dotenv
   VITE_FIREBASE_API_KEY=<apiKey>
   VITE_FIREBASE_AUTH_DOMAIN=<authDomain>
   VITE_FIREBASE_DATABASE_URL=https://<projectId>.firebaseio.com
   VITE_FIREBASE_PROJECT_ID=<projectId>
   VITE_FIREBASE_STORAGE_BUCKET=<storageBucket>
   VITE_FIREBASE_MESSAGING_SENDER_ID=<messagingSenderId>
   ```

   Commit that on a branch → PR to front4 `staging`. `yarn build:staging` must stay green. **This is the step that actually flips staging off `fbpackiot`** — do it only once the test user exists (steps 4–6), so staging login isn't broken in the gap.

---

## 4. Create a service-account key (for minting test users + future CS-Admin)

This is the **only secret** in this whole process. It authorizes the Firebase Admin SDK to create users and mint tokens **in the staging project**.

Firebase console → **Project settings → Service accounts** tab:

1. Click **Generate new private key** → **Generate key**. A JSON file downloads (e.g. `packiot-staging-firebase-adminsdk-xxxxx.json`).
2. **This file is a secret.** Treat it like a password:
   - ✅ Store it in the **staging secrets manager** (AWS Secrets Manager / SSM Parameter Store, whichever the staging stack uses) OR as an out-of-repo `.env` / mounted file on the staging host that runs the minting/CS-Admin process.
   - ❌ **Never** commit it to any repo. Do NOT drop it next to `back4-api/private-key.json` (that path is exactly the prod anti-pattern being retired — a service-account key living in a repo).
   - ❌ Never paste it into front4 (`.env.*`) — the browser must never see a service-account key. front4 only needs the **public** web config from step 3.
3. Note which project this key belongs to. **A staging SA key must only ever be pointed at the staging project** — the whole point of Decision 6 is that a mis-pointed key can't reach prod.

---

## 5. (Optional) Verify the project from the console

- **Authentication → Users** tab: should be empty (no users yet). You'll add the test user in step 6.
- **Authentication → Settings → Authorized domains**: Firebase auto-adds `localhost` + `*.firebaseapp.com` + `*.web.app`. Add the staging front4 origin (e.g. `staging.packiot.com` / the Amplify domain) so `signInWithEmailAndPassword` isn't blocked by domain policy on the deployed SPA.

---

## 6. Follow-up (NOT part of this guide — after steps 1–4) — mint the test user + seed the DB

Once the staging project + web config + service-account key exist, the migration follow-up (tracked under #54 / ADR-0033) is:

1. **Mint the `packiot` test user** in the **`packiot-staging`** project (Admin SDK `createUser`, using the step-4 staging SA key — NOT the dead prod key). Record its `uid`.
2. **Seed `users.id_user_firebase`** with that `uid` in **both** staging databases — the F1 (`packiot`) and F3 (`packiot_analytics`) planes — on a row that has a non-NULL `id_enterprise` and `active = true`, so refdata's `usersEnterpriseSQL` resolves it to a tenant. (A Firebase uid with no matching `users` row fails closed with 401 by design — see ADR-0033 §1.1.)
3. Do steps 1–2 **atomically per user** — this is exactly the CS-Admin provisioning flow ADR-0033 Decision 7 formalizes (create Firebase user in the correct per-ENV project **and** seed the `uid → id_enterprise` mapping in one transaction). For the one-off staging test user a manual mint + seed is fine; going forward CS-Admin owns this.

After that, flip `front4/.env.staging` (step 3) to the staging config and staging front4 login runs against `packiot-staging`, fully isolated from prod.

---

## 7. Cost & quota note

| Item | Cost |
|---|---|
| Additional Firebase project | **Free** (no per-project charge) |
| Standard Email/Password Auth | **Free** (Spark plan; generous free MAU tier) |
| Identity Platform (GCIP) | **NOT enabled** — would add per-MAU billing; not needed (DB-lookup tenancy) |
| Service-account key | Free |

Staging auth is effectively free. The only thing that would cost money is upgrading to Identity Platform, which this design deliberately avoids.

---

## Appendix A — equivalent `gcloud` / Terraform (REVIEW-ONLY — the USER runs after review; do NOT auto-run)

> ⚠️ These are provided for review and as an IaC alternative to the console clicks. **Do not auto-run them.** They mutate cloud state (project creation, API enablement, service-account + key creation). Run only after the USER reviews and consents, with the USER's own credentials. Nothing here should ever target `fbpackiot`.

**A.1 — create the project + enable Firebase (`gcloud` / `firebase`):**

```bash
# Requires an owner/creator role on the billing org. Review each line first.
gcloud projects create packiot-staging --name="packiot-staging"
# Add Firebase management to the GCP project:
firebase projects:addfirebase packiot-staging
# Register a web app + print its config (equivalent of §3):
firebase apps:create WEB front4-staging --project packiot-staging
firebase apps:sdkconfig WEB --project packiot-staging   # prints the six VITE_FIREBASE_* values
```

Email/Password sign-in is enabled in the console (§2) or via the Identity Toolkit Admin API; there is no first-class `firebase` CLI verb for it — the console toggle is simplest and is standard (non–Identity-Platform) Auth.

**A.2 — service account for the Admin SDK (§4), Terraform sketch:**

```hcl
# REVIEW-ONLY. Do not `terraform apply` without USER review. Never point at fbpackiot.
resource "google_service_account" "packiot_staging_admin" {
  project      = "packiot-staging"
  account_id   = "cs-admin-staging"
  display_name = "CS-Admin / test-user minting (STAGING only)"
}

resource "google_service_account_key" "packiot_staging_admin_key" {
  service_account_id = google_service_account.packiot_staging_admin.name
  # The private key lands in Terraform state — store state encrypted, and push the
  # key into the staging secrets manager; NEVER into a repo.
}

# The Firebase Admin SDK needs the Firebase Authentication Admin role:
resource "google_project_iam_member" "admin_sdk_auth" {
  project = "packiot-staging"
  role    = "roles/firebaseauth.admin"
  member  = "serviceAccount:${google_service_account.packiot_staging_admin.email}"
}
```

> Terraform note: a `google_service_account_key` puts the private key into Terraform **state** — treat the state backend as secret (encrypted remote state), and do not print the key. This is the standard tradeoff; many teams create the mint key by hand (§4) precisely to keep it out of state.

---

## What the USER must do to unblock staging front4 login (checklist)

1. **Create** Firebase project `packiot-staging` (§1).
2. **Enable** Email/Password auth (§2). Do **not** enable Identity Platform.
3. **Register** a Web app, **copy** the 6-value config (§3).
4. **Create** a service-account key, store it in the **staging** secrets manager / host `.env` — **not** the repo (§4).
5. Hand back the web config → front4 `.env.staging` gets flipped (PR to `staging`), and the test user is minted + DB-seeded (§6).
