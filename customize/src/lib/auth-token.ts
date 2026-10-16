import { auth } from "@/lib/firebase";
import { COGNITO_ENABLED, getCognitoSession } from "@/lib/cognito";

/**
 * auth-token.ts — the SINGLE dual-path credential provider (ported from
 * front4/src/services/authToken.js and the sibling barcode-scanner-v2). Every
 * outbound call layer asks this module "what bearer token do I attach?" instead
 * of reaching into Firebase directly. Centralizing it is what makes the
 * Firebase→Cognito swap a one-file change.
 *
 * DUAL-PATH CONTRACT (order matters):
 *   1. If the Cognito feature is ON *and* there is a live Cognito session,
 *      return the Cognito ID token.
 *   2. Otherwise fall back to Firebase — read a FRESH ID token from the current
 *      user (getIdToken auto-refreshes when expired). The auth-context state is
 *      derived from this same source, so this stays consistent with the UI.
 *
 * When VITE_AUTH_COGNITO_ENABLED is unset/false, COGNITO_ENABLED short-circuits
 * step 1 entirely, so this reduces to the pre-existing Firebase behavior. edge-api
 * accepts EITHER issuer (issuer-agnostic verifier, ADR-0033), so a call may carry
 * a Firebase token on one request and a Cognito token on the next with no server
 * change — the whole point of building the dual-path first.
 *
 * Returns the raw JWT string (NO "Bearer " prefix); the axios interceptor adds
 * the scheme. Returns null when unauthenticated (the interceptor then attaches
 * no header and the backend 401s — fail-closed).
 */
export async function getAuthToken(): Promise<string | null> {
  if (COGNITO_ENABLED) {
    const session = await getCognitoSession();
    if (session?.idToken) return session.idToken;
  }
  try {
    const token = await auth.currentUser?.getIdToken();
    return token ?? null;
  } catch {
    return null;
  }
}
