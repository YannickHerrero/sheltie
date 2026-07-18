import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AuthStore } from "../src/auth.ts";
import type { BridgeConfig } from "../src/config.ts";
import { createBridgeServer, type BridgeServer } from "../src/server.ts";
import type { BridgeStateProviding } from "../src/state-engine.ts";
import type { ActionCommand, ActionResult, BootstrapSnapshot } from "../src/types.ts";

let directory: string | null = null;
let bridge: BridgeServer | null = null;
afterEach(() => {
  bridge?.stop();
  bridge = null;
  if (directory) rmSync(directory, { recursive: true, force: true });
  directory = null;
});

function developmentConfig(): BridgeConfig {
  directory = mkdtempSync(join(tmpdir(), "sheltie-server-"));
  return {
    bindHost: "127.0.0.1",
    port: 0,
    configRoot: directory,
    primarySocketPath: join(directory, "herdr.sock"),
    dataDirectory: directory,
    instanceID: "studio",
    instanceName: "Mac Studio",
    publicHost: "studio.example.ts.net",
    expectedHost: null,
    allowedTailscaleLogins: new Set(),
    developmentMode: true,
    herdrBinary: "herdr",
    snapshotPollMilliseconds: 2_000,
    terminalPollMilliseconds: 350,
  };
}

function fixture(): BootstrapSnapshot {
  const url = new URL("../../protocol/Tests/SheltieProtocolTests/Fixtures/bootstrap-v1.json", import.meta.url);
  return JSON.parse(readFileSync(url, "utf8")) as BootstrapSnapshot;
}

class FakeState implements BridgeStateProviding {
  readonly actions: ActionCommand[] = [];
  readonly snapshot = fixture();
  get hasReachableSession() { return true; }
  async start() {}
  stop() {}
  async getSnapshot() { return this.snapshot; }
  async performAction(action: ActionCommand): Promise<ActionResult> {
    this.actions.push(action);
    return { requestID: action.requestID, ok: true, errorCode: null, message: null };
  }
  clientFor() { return null; }
  addSnapshotListener() { return () => {}; }
}

describe("bridge HTTP service", () => {
  test("serves health, short-lived sessions, bootstrap, and audited actions", async () => {
    const config = developmentConfig();
    const state = new FakeState();
    const auth = new AuthStore(config, { id: "studio", name: "Mac Studio", host: config.publicHost }, () => {});
    bridge = createBridgeServer(config, state, auth);
    const base = `http://127.0.0.1:${bridge.server.port}`;

    const health = await fetch(`${base}/v1/health`);
    expect(health.status).toBe(200);
    expect(await health.json()).toMatchObject({ ok: true, protocolVersion: 1, herdrReachable: true });

    const refresh = await fetch(`${base}/v1/session/refresh`, {
      method: "POST",
      headers: { authorization: "Bearer development" },
    });
    const refreshed = await refresh.json() as { sessionToken: string };
    expect(refreshed.sessionToken).not.toBeEmpty();

    const bootstrap = await fetch(`${base}/v1/bootstrap?session=default`, {
      headers: { authorization: `Bearer ${refreshed.sessionToken}` },
    });
    expect(bootstrap.status).toBe(200);
    expect((await bootstrap.json() as BootstrapSnapshot).workspaces[0]?.label).toBe("herdr");

    const action = {
      requestID: "request-1",
      sessionID: "default",
      type: "terminal.keys",
      targetID: "w1:p1",
      keys: ["ctrl+c"],
    };
    const response = await fetch(`${base}/v1/actions`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${refreshed.sessionToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(action),
    });
    expect(response.status).toBe(200);
    expect(state.actions).toHaveLength(1);
    const audit = readFileSync(join(config.dataDirectory, "audit.jsonl"), "utf8");
    expect(audit).toContain('"type":"terminal.keys"');
    expect(audit).not.toContain("ctrl+c");
  });

  test("rejects missing credentials and unknown actions", async () => {
    const config = developmentConfig();
    const state = new FakeState();
    const auth = new AuthStore(config, { id: "studio", name: "Mac Studio", host: config.publicHost }, () => {});
    bridge = createBridgeServer(config, state, auth);
    const base = `http://127.0.0.1:${bridge.server.port}`;

    expect((await fetch(`${base}/v1/bootstrap`)).status).toBe(401);
    const action = await fetch(`${base}/v1/actions`, {
      method: "POST",
      headers: { authorization: "Bearer development", "content-type": "application/json" },
      body: JSON.stringify({ requestID: "x", sessionID: "default", type: "server.stop" }),
    });
    expect(action.status).toBe(400);
    expect(state.actions).toHaveLength(0);
  });
});
