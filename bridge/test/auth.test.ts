import { afterEach, describe, expect, test } from "bun:test";
import { generateKeyPairSync, sign } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AuthenticationError, AuthStore, validateIngress } from "../src/auth.ts";
import type { BridgeConfig } from "../src/config.ts";

let directory: string | null = null;
afterEach(() => {
  if (directory) rmSync(directory, { recursive: true, force: true });
  directory = null;
});

function config(overrides: Partial<BridgeConfig> = {}): BridgeConfig {
  directory = mkdtempSync(join(tmpdir(), "sheltie-auth-"));
  return {
    bindHost: "127.0.0.1",
    port: 9847,
    configRoot: directory,
    primarySocketPath: join(directory, "herdr.sock"),
    dataDirectory: directory,
    instanceID: "studio",
    instanceName: "Mac Studio",
    publicHost: "studio.example.ts.net",
    expectedHost: "studio.example.ts.net",
    allowedTailscaleLogins: new Set(["owner@example.com"]),
    developmentMode: false,
    herdrBinary: "herdr",
    snapshotPollMilliseconds: 2_000,
    terminalPollMilliseconds: 350,
    ...overrides,
  };
}

describe("pairing and session authentication", () => {
  test("requires possession of the device key and the host-displayed code", () => {
    const keys = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
    let displayedCode = "";
    const store = new AuthStore(
      config(),
      { id: "studio", name: "Mac Studio", host: "studio.example.ts.net" },
      (message) => { displayedCode = message.match(/code (\d{6})/)?.[1] ?? ""; },
    );
    const started = store.startPairing("Yannick’s iPad", keys.publicKey.export({ format: "der", type: "spki" }).toString("base64"));
    expect(displayedCode).toHaveLength(6);

    expect(() => store.completePairing(started.pairingID, "000000", "bad-signature")).toThrow(AuthenticationError);

    const signature = sign("sha256", Buffer.from(started.challengeBase64, "base64"), keys.privateKey).toString("base64");
    const completed = store.completePairing(started.pairingID, displayedCode, signature);
    expect(completed.deviceID).not.toBeEmpty();
    expect(completed.instance.name).toBe("Mac Studio");

    const refreshed = store.refreshSession(new Request("https://studio.example.ts.net/v1/session/refresh", {
      headers: { authorization: `Bearer ${completed.accessToken}` },
    }));
    expect(refreshed.expiresAtMillis).toBeGreaterThan(Date.now());
    expect(store.authenticateSession(new Request("https://studio.example.ts.net/v1/bootstrap", {
      headers: { authorization: `Bearer ${refreshed.sessionToken}` },
    })).deviceID).toBe(completed.deviceID);

    expect(store.revoke(completed.deviceID)).toBeTrue();
    expect(() => store.authenticateSession(new Request("https://studio.example.ts.net/v1/bootstrap", {
      headers: { authorization: `Bearer ${refreshed.sessionToken}` },
    }))).toThrow(AuthenticationError);
  });

  test("validates host and Tailscale login outside development mode", () => {
    const production = config();
    expect(() => validateIngress(new Request("https://studio.example.ts.net/v1/health", {
      headers: { host: "studio.example.ts.net", "tailscale-user-login": "owner@example.com" },
    }), production)).not.toThrow();
    expect(() => validateIngress(new Request("https://evil.example/v1/health", {
      headers: { host: "evil.example", "tailscale-user-login": "owner@example.com" },
    }), production)).toThrow(AuthenticationError);
    expect(() => validateIngress(new Request("https://studio.example.ts.net/v1/health", {
      headers: { host: "studio.example.ts.net", "tailscale-user-login": "intruder@example.com" },
    }), production)).toThrow(AuthenticationError);
  });
});
