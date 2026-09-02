// Unit tests for the Cognito User Migration Lambda (ADR-0034).
// No live Firebase / AWS calls: global `fetch` is stubbed, and the web API key
// is injected via env so the Secrets Manager path is never exercised.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  handler,
  buildUserAttributes,
  firebaseSignInWithPassword,
  firebaseLookupByEmail,
  resolveWebApiKey,
  FirebaseAuthError,
} from "./index.mjs";

// A fake fetch Response.
function jsonResponse(status, body) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
  };
}

const AUTH_EVENT = {
  triggerSource: "UserMigration_Authentication",
  userName: "operator@factory.example",
  request: { password: "s3cret-pass" },
  response: {},
};

beforeEach(() => {
  process.env.MIGRATION_ENABLED = "true";
  process.env.FIREBASE_WEB_API_KEY = "test-web-api-key"; // bypasses Secrets Manager
});

afterEach(() => {
  vi.unstubAllGlobals();
  delete process.env.MIGRATION_ENABLED;
  delete process.env.FIREBASE_WEB_API_KEY;
});

describe("buildUserAttributes", () => {
  it("maps email, email_verified, name, and firebase uid", () => {
    const attrs = buildUserAttributes("a@b.com", {
      localId: "fb-uid-123",
      displayName: "Ada Lovelace",
    });
    expect(attrs).toEqual({
      email: "a@b.com",
      email_verified: "true",
      name: "Ada Lovelace",
      "custom:firebase_uid": "fb-uid-123",
    });
  });

  it("omits optional attributes when absent", () => {
    const attrs = buildUserAttributes("a@b.com", {});
    expect(attrs).toEqual({ email: "a@b.com", email_verified: "true" });
  });
});

describe("handler — UserMigration_Authentication", () => {
  it("on Firebase success maps attributes + CONFIRMED + SUPPRESS", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        jsonResponse(200, {
          localId: "fb-uid-abc",
          email: "operator@factory.example",
          displayName: "Line Op",
        })
      )
    );

    const event = structuredClone(AUTH_EVENT);
    const out = await handler(event);

    expect(out.response.finalUserStatus).toBe("CONFIRMED");
    expect(out.response.messageAction).toBe("SUPPRESS");
    expect(out.response.userAttributes).toEqual({
      email: "operator@factory.example",
      email_verified: "true",
      name: "Line Op",
      "custom:firebase_uid": "fb-uid-abc",
    });

    // The password must never appear in the outgoing request URL.
    const calledUrl = fetch.mock.calls[0][0];
    expect(calledUrl).toContain("accounts:signInWithPassword");
    expect(calledUrl).not.toContain("s3cret-pass");
  });

  it("throws on INVALID_PASSWORD (auth denied)", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        jsonResponse(400, { error: { message: "INVALID_PASSWORD" } })
      )
    );
    await expect(handler(structuredClone(AUTH_EVENT))).rejects.toThrow();
  });

  it("throws on EMAIL_NOT_FOUND (auth denied)", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        jsonResponse(400, { error: { message: "EMAIL_NOT_FOUND" } })
      )
    );
    await expect(handler(structuredClone(AUTH_EVENT))).rejects.toThrow();
  });

  it("throws on USER_DISABLED (auth denied)", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        jsonResponse(400, { error: { message: "USER_DISABLED" } })
      )
    );
    await expect(handler(structuredClone(AUTH_EVENT))).rejects.toThrow();
  });

  it("denies when MIGRATION_ENABLED is not true (no Firebase call)", async () => {
    process.env.MIGRATION_ENABLED = "false";
    const spy = vi.fn();
    vi.stubGlobal("fetch", spy);
    await expect(handler(structuredClone(AUTH_EVENT))).rejects.toThrow();
    expect(spy).not.toHaveBeenCalled();
  });
});

describe("handler — UserMigration_ForgotPassword", () => {
  const forgotEvent = {
    triggerSource: "UserMigration_ForgotPassword",
    userName: "operator@factory.example",
    request: {},
    response: {},
  };

  it("returns attributes + SUPPRESS when the user exists in Firebase", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse(200, { registered: true }))
    );
    const out = await handler(structuredClone(forgotEvent));
    expect(out.response.messageAction).toBe("SUPPRESS");
    expect(out.response.userAttributes.email).toBe("operator@factory.example");
    expect(out.response.userAttributes.email_verified).toBe("true");
  });

  it("throws when the user is not registered in Firebase", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse(200, { registered: false }))
    );
    await expect(handler(structuredClone(forgotEvent))).rejects.toThrow();
  });
});

describe("handler — unsupported trigger", () => {
  it("throws on an unknown triggerSource", async () => {
    vi.stubGlobal("fetch", vi.fn());
    await expect(
      handler({ triggerSource: "PreSignUp_SignUp", response: {} })
    ).rejects.toThrow(/Unsupported/);
  });
});

describe("firebase REST helpers", () => {
  it("firebaseSignInWithPassword throws FirebaseAuthError with the code", async () => {
    const fetchImpl = vi.fn(async () =>
      jsonResponse(400, { error: { message: "INVALID_LOGIN_CREDENTIALS" } })
    );
    await expect(
      firebaseSignInWithPassword("a@b.com", "pw", "k", { fetchImpl })
    ).rejects.toMatchObject({
      name: "FirebaseAuthError",
      code: "INVALID_LOGIN_CREDENTIALS",
    });
  });

  it("firebaseLookupByEmail reports registered=false", async () => {
    const fetchImpl = vi.fn(async () => jsonResponse(200, { registered: false }));
    const out = await firebaseLookupByEmail("a@b.com", "k", { fetchImpl });
    expect(out.registered).toBe(false);
  });
});

describe("resolveWebApiKey", () => {
  it("prefers a directly-set env var over Secrets Manager", async () => {
    const smClient = { send: vi.fn() };
    const key = await resolveWebApiKey({
      env: { FIREBASE_WEB_API_KEY: "direct-key" },
      smClient,
    });
    expect(key).toBe("direct-key");
    expect(smClient.send).not.toHaveBeenCalled();
  });

  it("fetches from Secrets Manager (JSON shape) when no direct env var", async () => {
    const smClient = {
      send: vi.fn(async () => ({
        SecretString: JSON.stringify({ web_api_key: "sm-key" }),
      })),
    };
    const key = await resolveWebApiKey({
      env: { FIREBASE_WEB_API_KEY_SECRET_ID: "packiot/staging/firebase-web-api-key" },
      smClient,
    });
    expect(key).toBe("sm-key");
    expect(smClient.send).toHaveBeenCalledOnce();
  });

  it("throws when nothing is configured", async () => {
    await expect(
      resolveWebApiKey({ env: {}, smClient: { send: vi.fn() } })
    ).rejects.toThrow();
  });
});

describe("FirebaseAuthError", () => {
  it("carries a stable code", () => {
    const e = new FirebaseAuthError("INVALID_PASSWORD");
    expect(e.code).toBe("INVALID_PASSWORD");
    expect(e).toBeInstanceOf(Error);
  });
});
