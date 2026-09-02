// cognito-user-migration — Cognito User Migration trigger Lambda (ADR-0034)
// ═══════════════════════════════════════════════════════════════════════════
//
// WHY THIS EXISTS
// ───────────────
// ADR-0034 migrates front4's identity provider from Firebase to an AWS Cognito
// user pool. Firebase stores passwords as project-specific scrypt hashes that
// Cognito cannot import, so a bulk import would force EVERY user to reset their
// password. Instead this Lambda implements the AWS-documented "migrate-on-login"
// (JIT) path: the FIRST time a not-yet-in-Cognito user signs in, Cognito invokes
// this trigger with the plaintext password (over TLS, in-Lambda only); we
// validate it against Firebase's Identity Toolkit REST API; on success Cognito
// creates the user natively carrying that same password. Zero forced resets.
//
// SECURITY POSTURE (ADR-0034 §4 + OQ-4)
// ─────────────────────────────────────
//   • Uses the Firebase WEB API KEY (the semi-public Identity Toolkit key client
//     apps use for signInWithPassword) — NOT the retired Admin service-account
//     private key. It is a read-only password check, sourced from Secrets
//     Manager at runtime, NEVER hardcoded, NEVER logged.
//   • The Firebase project the key belongs to is a CONFIG value. Until the USER
//     deliberately flips config at cutover, this points at nothing production.
//   • MIGRATION_ENABLED gates the whole trigger. Default OFF: wiring the trigger
//     onto the pool is inert (every invocation denies) until the USER enables it.
//   • Passwords and key material are never written to logs. Structured JSON logs
//     carry only the trigger source, the (non-secret) email, and outcome codes.
//
// This handler has ZERO third-party runtime dependencies: it uses the Node 20
// runtime's global `fetch` and the AWS SDK v3 Secrets Manager client that the
// Lambda runtime already bundles. Nothing to `npm install` into the zip.

import {
  SecretsManagerClient,
  GetSecretValueCommand,
} from "@aws-sdk/client-secrets-manager";

// ── Config (all via env; no secret values baked in) ──────────────────────────

const IDENTITY_TOOLKIT_BASE = "https://identitytoolkit.googleapis.com/v1";

// The two Cognito trigger sources this Lambda answers.
const TRIGGER_AUTH = "UserMigration_Authentication";
const TRIGGER_FORGOT = "UserMigration_ForgotPassword";

// Custom pool attribute that carries the Firebase uid (localId) forward, so a
// later reconciler can map Firebase uid ↔ Cognito sub. Configurable + skippable:
// if the pool does not declare this attribute, set FIREBASE_UID_ATTRIBUTE="" and
// the mapping is dropped (email stays the natural key — ADR-0034 §4 prefers
// email-keyed reconciliation anyway).
const FIREBASE_UID_ATTRIBUTE =
  process.env.FIREBASE_UID_ATTRIBUTE === undefined
    ? "custom:firebase_uid"
    : process.env.FIREBASE_UID_ATTRIBUTE;

// ── Structured logging (never logs secrets or passwords) ─────────────────────

function log(level, message, fields = {}) {
  // Defensive: never let a caller smuggle a secret into a log field.
  const { password, key, apiKey, secret, ...safe } = fields;
  const line = JSON.stringify({
    level,
    service: "cognito-user-migration",
    message,
    ...safe,
  });
  if (level === "error") console.error(line);
  else console.log(line);
}

// ── Web API key resolution (Secrets Manager, cached across warm invocations) ──

let cachedApiKey;
let secretsClient;

function getSecretsClient() {
  if (!secretsClient) {
    secretsClient = new SecretsManagerClient({});
  }
  return secretsClient;
}

// Resolve the Firebase WEB API key. Two seams, in priority order:
//   1. FIREBASE_WEB_API_KEY set directly in env (local dev / tests only).
//   2. FIREBASE_WEB_API_KEY_SECRET_ID → fetch from Secrets Manager at runtime
//      (the production seam — the value lives ONLY in Secrets Manager, never in
//      code, env, or terraform state).
// The resolved value is cached on the warm container. It is never logged.
export async function resolveWebApiKey({ env, smClient } = {}) {
  // The warm-container cache is only used on the default (production) path — when
  // callers inject their own env/smClient (tests) the module cache is bypassed so
  // one test cannot leak a resolved value into the next.
  const useCache = env === undefined && smClient === undefined;
  const resolvedEnv = env ?? process.env;
  const resolvedClient = smClient ?? getSecretsClient();

  if (resolvedEnv.FIREBASE_WEB_API_KEY) {
    return resolvedEnv.FIREBASE_WEB_API_KEY;
  }
  if (useCache && cachedApiKey) {
    return cachedApiKey;
  }
  const secretId = resolvedEnv.FIREBASE_WEB_API_KEY_SECRET_ID;
  if (!secretId) {
    throw new Error(
      "no Firebase web API key configured (set FIREBASE_WEB_API_KEY or FIREBASE_WEB_API_KEY_SECRET_ID)"
    );
  }
  const out = await resolvedClient.send(
    new GetSecretValueCommand({ SecretId: secretId })
  );
  const raw = out.SecretString ?? "";
  // Support either a bare string secret or a JSON {"web_api_key":"..."} shape.
  let value = raw;
  const trimmed = raw.trim();
  if (trimmed.startsWith("{")) {
    try {
      const obj = JSON.parse(trimmed);
      value = obj.web_api_key ?? obj.api_key ?? obj.key ?? "";
    } catch {
      value = raw;
    }
  }
  if (!value) {
    throw new Error("Firebase web API key secret is empty or malformed");
  }
  if (useCache) {
    cachedApiKey = value;
  }
  return value;
}

// ── Firebase Identity Toolkit REST calls (web-key auth only) ─────────────────

// Verify email+password against Firebase. Returns the user record on success,
// throws a FirebaseAuthError (with a stable .code) on any failure. The web API
// key travels ONLY as the `key` query param over TLS and is never logged.
export async function firebaseSignInWithPassword(
  email,
  password,
  apiKey,
  { fetchImpl = fetch } = {}
) {
  const res = await fetchImpl(
    `${IDENTITY_TOOLKIT_BASE}/accounts:signInWithPassword?key=${encodeURIComponent(
      apiKey
    )}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email, password, returnSecureToken: true }),
    }
  );
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const code = data?.error?.message || `HTTP_${res.status}`;
    throw new FirebaseAuthError(code);
  }
  return data; // { localId, email, displayName?, ... }
}

// Existence check by email using createAuthUri (web-key accessible — no admin
// creds, no password needed). Used by the ForgotPassword trigger to confirm the
// user is a real Firebase user before letting Cognito send a reset code.
export async function firebaseLookupByEmail(
  email,
  apiKey,
  { fetchImpl = fetch } = {}
) {
  const res = await fetchImpl(
    `${IDENTITY_TOOLKIT_BASE}/accounts:createAuthUri?key=${encodeURIComponent(
      apiKey
    )}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        identifier: email,
        continueUri: "http://localhost", // required by the API, unused by us
      }),
    }
  );
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const code = data?.error?.message || `HTTP_${res.status}`;
    throw new FirebaseAuthError(code);
  }
  return { registered: data?.registered === true, ...data };
}

export class FirebaseAuthError extends Error {
  constructor(code) {
    super(code);
    this.name = "FirebaseAuthError";
    this.code = code;
  }
}

// ── Attribute mapping ────────────────────────────────────────────────────────

// Build the Cognito userAttributes map from a Firebase user record.
export function buildUserAttributes(email, firebaseUser = {}) {
  const attrs = {
    email,
    email_verified: "true",
  };
  if (firebaseUser.displayName) {
    attrs.name = firebaseUser.displayName;
  }
  if (FIREBASE_UID_ATTRIBUTE && firebaseUser.localId) {
    attrs[FIREBASE_UID_ATTRIBUTE] = firebaseUser.localId;
  }
  return attrs;
}

// ── Trigger handlers ─────────────────────────────────────────────────────────

async function handleAuthentication(event, apiKey, deps) {
  const email = event.userName;
  const password = event?.request?.password;
  if (!email || !password) {
    log("warn", "authentication trigger missing email or password", {
      hasEmail: Boolean(email),
    });
    throw new Error("Bad credentials");
  }

  let firebaseUser;
  try {
    firebaseUser = await firebaseSignInWithPassword(
      email,
      password,
      apiKey,
      deps
    );
  } catch (err) {
    // INVALID_PASSWORD / EMAIL_NOT_FOUND / USER_DISABLED / INVALID_LOGIN_CREDENTIALS
    // all collapse to a single opaque denial — never leak which failed.
    log("info", "firebase password verification denied", {
      email,
      code: err.code || "UNKNOWN",
    });
    throw new Error("Bad credentials"); // Cognito → generic auth failure
  }

  event.response.userAttributes = buildUserAttributes(email, firebaseUser);
  event.response.finalUserStatus = "CONFIRMED"; // user keeps their password
  event.response.messageAction = "SUPPRESS"; // no welcome email
  log("info", "user migrated on authentication", {
    email,
    trigger: TRIGGER_AUTH,
  });
  return event;
}

async function handleForgotPassword(event, apiKey, deps) {
  const email = event.userName;
  if (!email) {
    throw new Error("Bad credentials");
  }

  // We cannot verify a password here (the user has forgotten it), so we confirm
  // the account exists in Firebase before letting Cognito send a reset code.
  let lookup;
  try {
    lookup = await firebaseLookupByEmail(email, apiKey, deps);
  } catch (err) {
    log("info", "firebase lookup failed during forgot-password", {
      email,
      code: err.code || "UNKNOWN",
    });
    throw new Error("Bad credentials");
  }
  if (!lookup.registered) {
    log("info", "forgot-password for unknown firebase user", { email });
    throw new Error("Bad credentials"); // user can't be found → deny
  }

  // Return attributes so Cognito creates the user and drives its own reset flow.
  event.response.userAttributes = buildUserAttributes(email, {});
  event.response.messageAction = "SUPPRESS";
  log("info", "user staged for password reset", {
    email,
    trigger: TRIGGER_FORGOT,
  });
  return event;
}

// ── Lambda entrypoint ────────────────────────────────────────────────────────

export const handler = async (event) => {
  const trigger = event?.triggerSource;
  log("info", "invoked", { trigger });

  // Gate: default OFF. Wiring the trigger onto the pool is inert until the USER
  // sets MIGRATION_ENABLED=true at cutover.
  if (String(process.env.MIGRATION_ENABLED).toLowerCase() !== "true") {
    log("warn", "migration disabled — denying", { trigger });
    throw new Error("Bad credentials");
  }

  const apiKey = await resolveWebApiKey();
  const deps = {}; // real fetch; overridden in tests

  switch (trigger) {
    case TRIGGER_AUTH:
      return handleAuthentication(event, apiKey, deps);
    case TRIGGER_FORGOT:
      return handleForgotPassword(event, apiKey, deps);
    default:
      log("error", "unsupported trigger source", { trigger });
      throw new Error(`Unsupported triggerSource: ${trigger}`);
  }
};
