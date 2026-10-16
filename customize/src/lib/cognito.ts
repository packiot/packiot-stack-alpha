import { Amplify } from "aws-amplify";
import {
  signIn as amplifySignIn,
  signOut as amplifySignOut,
  fetchAuthSession,
} from "aws-amplify/auth";

/**
 * cognito.ts — the ADDITIVE AWS Cognito (Amplify Auth) identity path, the
 * go-forward IdP that will eventually REPLACE Firebase (firebase.ts) as part of
 * the GCP-exit (ADR-0034 / ADR-0041). Ported from front4/src/cognito.js and the
 * sibling barcode-scanner-v2/src/lib/cognito.ts: it configures the SDK and
 * exposes the primitives the auth layer needs (sign-in, sign-out, "give me the
 * current ID token").
 *
 * IT IS DARK BY DEFAULT. Nothing here runs unless VITE_AUTH_COGNITO_ENABLED is
 * "true" AND both the pool id and app-client id are provided via env. When the
 * flag is off, COGNITO_ENABLED is false, Amplify is never configured, and every
 * helper is a no-op that returns null — so the Firebase path is byte-for-byte
 * unaffected. This is a dual-path migration, not a cutover: edge-api (ADR-0033)
 * runs an issuer-agnostic verifier that accepts EITHER a Firebase or a Cognito
 * JWT, so CS Admin can flip over independently of the other clients.
 *
 * NO SECRETS ARE HARDCODED. A Cognito user-pool client id and pool id are PUBLIC
 * identifiers (they ship in every browser SPA that uses Cognito — a public SPA
 * app-client has no client secret), but we still source them from env so
 * staging/dev/prod stay separable. Amplify derives the region from the pool id
 * (`us-east-1_xxxx`), so no separate region var is needed.
 *
 * WHAT THE BACKEND TRUSTS. We send the Cognito ID token (token_use=id) because
 * it carries `aud` = app-client id (what the verifier checks) and the
 * `sub`/email + `cognito:groups` claims tenant-resolution and CS-Admin
 * escalation need. The access token has no `aud` and no email, so it is NOT
 * what we send.
 */

const userPoolId = import.meta.env.VITE_COGNITO_USER_POOL_ID;
const userPoolClientId = import.meta.env.VITE_COGNITO_CLIENT_ID;

/**
 * COGNITO_ENABLED — the single build-time gate for the whole Cognito path.
 * ANDed with "both ids present" so a half-configured env can never half-enable
 * it. `String(undefined) !== "true"` ⇒ default OFF.
 */
export const COGNITO_ENABLED =
  String(import.meta.env.VITE_AUTH_COGNITO_ENABLED).toLowerCase() === "true" &&
  Boolean(userPoolId) &&
  Boolean(userPoolClientId);

if (COGNITO_ENABLED) {
  Amplify.configure({
    Auth: {
      Cognito: {
        userPoolId: userPoolId as string,
        userPoolClientId: userPoolClientId as string,
        // SPA public client: no secret, USER_PASSWORD/SRP auth flow.
        loginWith: { username: false, email: true },
      },
    },
  });
}

export type CognitoSession = {
  idToken: string;
  sub?: string;
  email?: string;
};

/**
 * getCognitoSession — returns the current Cognito ID token + `sub`/email, or
 * null when there is no active Cognito session (or the feature is off). This is
 * what the dual-path token provider (auth-token.ts) calls to decide whether a
 * Cognito credential is available to attach to API calls.
 */
export async function getCognitoSession(): Promise<CognitoSession | null> {
  if (!COGNITO_ENABLED) return null;
  try {
    const session = await fetchAuthSession();
    const idTokenObj = session?.tokens?.idToken;
    const idToken = idTokenObj?.toString();
    if (!idToken) return null;
    return {
      idToken,
      sub: idTokenObj?.payload?.sub as string | undefined,
      email: idTokenObj?.payload?.email as string | undefined,
    };
  } catch {
    return null;
  }
}

/**
 * cognitoSignIn — email/password sign-in against the configured user pool.
 * Amplify throws "There is already a signed in user" if a stale session exists,
 * so we defensively sign out first.
 */
export async function cognitoSignIn(email: string, password: string) {
  if (!COGNITO_ENABLED) {
    throw new Error("Cognito auth path is disabled (VITE_AUTH_COGNITO_ENABLED)");
  }
  try {
    await amplifySignOut();
  } catch {
    /* no active session — fine */
  }
  return amplifySignIn({ username: email, password });
}

/** cognitoSignOut — no-op when the path is off; safe to call unconditionally. */
export async function cognitoSignOut() {
  if (!COGNITO_ENABLED) return;
  try {
    await amplifySignOut();
  } catch {
    /* already signed out */
  }
}
