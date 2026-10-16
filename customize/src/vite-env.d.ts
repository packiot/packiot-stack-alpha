/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** edge-api base URL — the ADR-0026 control plane (topology + writes). */
  readonly VITE_EDGE_API_URL: string;
  // Auth — Firebase (legacy IdP, default path)
  readonly VITE_FIREBASE_API_KEY: string;
  readonly VITE_FIREBASE_AUTH_DOMAIN: string;
  readonly VITE_FIREBASE_PROJECT_ID: string;
  readonly VITE_FIREBASE_STORAGE_BUCKET: string;
  readonly VITE_FIREBASE_MESSAGING_SENDER_ID: string;
  readonly VITE_FIREBASE_APP_ID: string;
  // Auth — Cognito (go-forward IdP, ADR-0034). Additive + dark by default.
  readonly VITE_AUTH_COGNITO_ENABLED: string;
  readonly VITE_COGNITO_USER_POOL_ID: string;
  readonly VITE_COGNITO_CLIENT_ID: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
