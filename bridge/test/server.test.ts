import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AuthStore } from "../src/auth.ts";
import type { BridgeConfig } from "../src/config.ts";
import { createBridgeServer, type BridgeServer } from "../src/server.ts";
import type { HerdrClient } from "../src/herdr-client.ts";
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
  readonly historyReads: Array<{ paneID: string; lines: number; source: string }> = [];
  readonly snapshot = fixture();
  get hasReachableSession() { return true; }
  async start() {}
  stop() {}
  async getSnapshot() { return this.snapshot; }
  async performAction(action: ActionCommand): Promise<ActionResult> {
    this.actions.push(action);
    return { requestID: action.requestID, ok: true, errorCode: null, message: null };
  }
  clientFor() {
    return {
      readPane: async (paneID: string, lines: number, source: string) => {
        this.historyReads.push({ paneID, lines, source });
        return { text: "older output\r\nlatest output\r\n", revision: 0, truncated: false };
      },
    } as unknown as HerdrClient;
  }
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

  test("serves bounded terminal history over an authenticated stream", async () => {
    const config = developmentConfig();
    const state = new FakeState();
    const auth = new AuthStore(config, { id: "studio", name: "Mac Studio", host: config.publicHost }, () => {});
    bridge = createBridgeServer(config, state, auth);
    const base = `http://127.0.0.1:${bridge.server.port}`;
    const refresh = await fetch(`${base}/v1/session/refresh`, {
      method: "POST",
      headers: { authorization: "Bearer development" },
    });
    const { sessionToken } = await refresh.json() as { sessionToken: string };

    const history = await new Promise<Record<string, unknown>>((resolve, reject) => {
      const AuthenticatedWebSocket = WebSocket as unknown as new (
        url: string,
        options: { headers: Record<string, string> },
      ) => WebSocket;
      const socket = new AuthenticatedWebSocket(
        `${base.replace("http", "ws")}/v1/stream?session=default`,
        { headers: { authorization: `Bearer ${sessionToken}` } },
      );
      const timeout = setTimeout(() => reject(new Error("terminal history timeout")), 2_000);
      socket.onmessage = (event) => {
        const message = JSON.parse(String(event.data)) as { type: string; history?: Record<string, unknown> };
        if (message.type === "snapshot") {
          socket.send(JSON.stringify({
            type: "terminal.history.request",
            request: { requestID: "history-1", sessionID: "default", paneID: "w1:p1", lines: 5_000 },
          }));
        } else if (message.type === "terminal.history" && message.history) {
          clearTimeout(timeout);
          socket.close();
          resolve(message.history);
        }
      };
      socket.onerror = () => {
        clearTimeout(timeout);
        reject(new Error("terminal history websocket failed"));
      };
    });

    expect(history).toMatchObject({
      requestID: "history-1",
      sessionID: "default",
      paneID: "w1:p1",
      requestedLines: 1_000,
      errorMessage: null,
    });
    expect(Buffer.from(String(history.bytesBase64), "base64").toString("utf8")).toContain("older output");
    expect(state.historyReads).toEqual([{ paneID: "w1:p1", lines: 1_000, source: "recent" }]);
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
