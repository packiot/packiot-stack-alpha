import { initializeApp } from "firebase/app";
import { getAuth, type Auth } from "firebase/auth";

const firebaseConfig = {
  apiKey: import.meta.env.VITE_FIREBASE_API_KEY,
  authDomain: import.meta.env.VITE_FIREBASE_AUTH_DOMAIN,
  projectId: import.meta.env.VITE_FIREBASE_PROJECT_ID,
  storageBucket: import.meta.env.VITE_FIREBASE_STORAGE_BUCKET,
  messagingSenderId: import.meta.env.VITE_FIREBASE_MESSAGING_SENDER_ID,
  appId: import.meta.env.VITE_FIREBASE_APP_ID,
};

// Firebase is the LEGACY auth path (ADR-0033/0034); the new stack uses Cognito.
// getAuth() validates the apiKey EAGERLY and throws `auth/invalid-api-key` at
// module load when VITE_FIREBASE_* are blank — which white-pages the whole SPA
// on a Cognito-only build (auth-context imports `auth` unconditionally, even
// though every Firebase call site is gated behind !COGNITO_ENABLED).
//
// So only initialize Firebase when an apiKey is actually configured. On a
// Cognito-only build, `auth` is a lazy stub that throws a CLEAR error only if
// the (gated-off) Firebase path is ever actually exercised — never at load.
export const auth: Auth = firebaseConfig.apiKey
  ? getAuth(initializeApp(firebaseConfig))
  : (new Proxy(
      {},
      {
        get() {
          throw new Error(
            "Firebase auth is not configured (VITE_FIREBASE_* are empty). " +
              "This is a Cognito build — VITE_AUTH_COGNITO_ENABLED must be true.",
          );
        },
      },
    ) as Auth);
