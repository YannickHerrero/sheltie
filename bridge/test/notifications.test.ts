import { expect, test } from "bun:test";
import type { AuthStore } from "../src/auth.ts";
import type { PushSending } from "../src/apns.ts";
import { AgentNotificationService } from "../src/notifications.ts";
import type { BridgeStateProviding } from "../src/state-engine.ts";
import type { BootstrapSnapshot } from "../src/types.ts";

function snapshot(status: "working" | "done" | "blocked"): BootstrapSnapshot {
  return {
    protocolVersion: 1,
    bridge: { version: "0.1.0", protocolVersion: 1, capabilities: [] },
    instance: { id: "studio", name: "Studio", host: "studio.ts.net" },
    herdr: { version: "0.7.4", protocolVersion: 18, capabilities: [] },
    sessions: [], activeSessionID: "default", workspaces: [], tabs: [], panes: [], layouts: [], usageMeters: [],
    agents: [{ id: "agent-1", paneID: "w1:p1", workspaceID: "w1", tabID: "w1:t1", name: "codex", displayName: "Codex", status, statusLabel: null }],
    focus: { workspaceID: null, tabID: null, paneID: null }, generatedAtMillis: 1,
  };
}

test("notifies only on post-bootstrap done and blocked transitions", async () => {
  let listener: ((snapshot: BootstrapSnapshot) => void) | null = null;
  const state = {
    addSnapshotListener(value: (snapshot: BootstrapSnapshot) => void) { listener = value; return () => { listener = null; }; },
  } as unknown as BridgeStateProviding;
  const cleared: string[] = [];
  const auth = {
    notificationTargets: () => [{ deviceID: "device-1", deviceToken: "ab".repeat(32) }],
    clearNotificationToken: (deviceID: string) => cleared.push(deviceID),
  } as unknown as AuthStore;
  const sent: string[] = [];
  const sender: PushSending = {
    async send(_token, status) {
      sent.push(status);
      return { accepted: true, invalidToken: false };
    },
  };
  const service = new AgentNotificationService(state, auth, sender);
  service.start();

  listener!(snapshot("working"));
  listener!(snapshot("working"));
  expect(sent).toEqual([]);
  listener!(snapshot("done"));
  await Bun.sleep(0);
  expect(sent).toEqual(["done"]);
  listener!(snapshot("done"));
  await Bun.sleep(0);
  expect(sent).toEqual(["done"]);
  listener!(snapshot("blocked"));
  await Bun.sleep(0);
  expect(sent).toEqual(["done", "blocked"]);
  expect(cleared).toEqual([]);
  service.stop();
});
