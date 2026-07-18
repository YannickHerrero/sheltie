import { adaptSnapshot, compareVersions } from "./adapter.ts";
import type { BridgeConfig } from "./config.ts";
import { HerdrClient } from "./herdr-client.ts";
import { discoverSessions, type HerdrSessionLocation } from "./sessions.ts";
import { loadUsageMeters } from "./usage.ts";
import type {
  ActionCommand,
  ActionResult,
  BootstrapSnapshot,
  InstanceInfo,
  RawHerdrSnapshot,
  RawLayoutDescription,
  SessionSummary,
} from "./types.ts";

interface EventWatcher {
  signature: string;
  close(): void;
}

interface SessionFetch {
  location: HerdrSessionLocation;
  raw: RawHerdrSnapshot | null;
  layouts: Map<string, RawLayoutDescription>;
}

export interface BridgeStateProviding {
  start(): Promise<void>;
  stop(): void;
  getSnapshot(sessionID?: string | null): Promise<BootstrapSnapshot>;
  performAction(action: ActionCommand): Promise<ActionResult>;
  clientFor(sessionID: string): HerdrClient | null;
  addSnapshotListener(listener: (snapshot: BootstrapSnapshot) => void): () => void;
  get hasReachableSession(): boolean;
}

export class BridgeStateEngine implements BridgeStateProviding {
  private readonly clients = new Map<string, HerdrClient>();
  private readonly locations = new Map<string, HerdrSessionLocation>();
  private readonly snapshots = new Map<string, BootstrapSnapshot>();
  private readonly listeners = new Set<(snapshot: BootstrapSnapshot) => void>();
  private readonly eventWatchers = new Map<string, EventWatcher>();
  private timer: Timer | null = null;
  private eventRefreshTimer: Timer | null = null;
  private refreshing: Promise<void> | null = null;

  constructor(
    private readonly config: BridgeConfig,
    private readonly instance: InstanceInfo,
  ) {}

  get hasReachableSession(): boolean {
    return this.snapshots.size > 0;
  }

  async start(): Promise<void> {
    await this.refresh();
    this.timer = setInterval(() => void this.refresh(), this.config.snapshotPollMilliseconds);
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    if (this.eventRefreshTimer) clearTimeout(this.eventRefreshTimer);
    this.timer = null;
    this.eventRefreshTimer = null;
    for (const watcher of this.eventWatchers.values()) watcher.close();
    this.eventWatchers.clear();
  }

  addSnapshotListener(listener: (snapshot: BootstrapSnapshot) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  clientFor(sessionID: string): HerdrClient | null {
    return this.clients.get(sessionID) ?? null;
  }

  async getSnapshot(sessionID?: string | null): Promise<BootstrapSnapshot> {
    if (this.snapshots.size === 0) await this.refresh();
    const requested = sessionID && this.snapshots.has(sessionID) ? sessionID : this.preferredSessionID();
    const snapshot = requested ? this.snapshots.get(requested) : null;
    if (!snapshot) throw new Error("no reachable Herdr session");
    return snapshot;
  }

  async performAction(action: ActionCommand): Promise<ActionResult> {
    const client = this.clients.get(action.sessionID);
    if (!client) return failure(action, "session_unavailable", "Herdr session is unavailable");

    try {
      await this.dispatch(client, action);
      void this.refresh();
      return { requestID: action.requestID, ok: true, errorCode: null, message: null };
    } catch (error) {
      return failure(action, "action_failed", error instanceof Error ? error.message : String(error));
    }
  }

  private async dispatch(client: HerdrClient, action: ActionCommand): Promise<void> {
    const target = () => required(action.targetID, "targetID");
    switch (action.type) {
      case "workspace.focus":
        return await client.perform("workspace.focus", { workspace_id: target() });
      case "workspace.create":
        return await client.perform("workspace.create", {
          cwd: required(action.cwd, "cwd"),
          ...(action.label ? { label: action.label } : {}),
          focus: true,
        });
      case "workspace.rename":
        return await client.perform("workspace.rename", { workspace_id: target(), label: required(action.label, "label") });
      case "workspace.close":
        return await client.perform("workspace.close", { workspace_id: target() });
      case "tab.focus":
        return await client.perform("tab.focus", { tab_id: target() });
      case "tab.create":
        return await client.perform("tab.create", {
          workspace_id: target(),
          ...(action.label ? { label: action.label } : {}),
          ...(action.cwd ? { cwd: action.cwd } : {}),
          focus: true,
        });
      case "tab.rename":
        return await client.perform("tab.rename", { tab_id: target(), label: required(action.label, "label") });
      case "tab.close":
        return await client.perform("tab.close", { tab_id: target() });
      case "pane.focus":
        return await client.perform("pane.focus", { pane_id: target() });
      case "pane.split":
        return await client.perform("pane.split", {
          target_pane_id: target(),
          direction: required(action.splitDirection, "splitDirection"),
          ...(action.ratio ? { ratio: action.ratio } : {}),
          ...(action.cwd ? { cwd: action.cwd } : {}),
          focus: true,
        });
      case "pane.move":
        return await client.perform("pane.move", {
          pane_id: target(),
          destination: herdrMoveDestination(required(action.moveDestination, "moveDestination")),
          focus: true,
        });
      case "pane.resize":
        return await client.perform("pane.resize", {
          pane_id: target(),
          direction: required(action.paneDirection, "paneDirection"),
          ...(action.ratio ? { amount: action.ratio } : {}),
        });
      case "layout.set_split_ratio":
        return await client.perform("layout.set_split_ratio", {
          tab_id: target(),
          path: action.splitPath ?? [],
          ratio: clampedRatio(required(action.ratio, "ratio")),
        });
      case "pane.zoom":
        return await client.perform("pane.zoom", { pane_id: target(), mode: "toggle" });
      case "pane.rename":
        return await client.perform("pane.rename", { pane_id: target(), label: action.label ?? null });
      case "pane.close":
        return await client.perform("pane.close", { pane_id: target() });
      case "terminal.input": {
        const text = terminalText(action);
        if (Buffer.byteLength(text, "utf8") > 64 * 1024) throw new Error("terminal input exceeds 64 KiB");
        if (action.keys?.length) {
          return await client.perform("pane.send_input", { pane_id: target(), text, keys: action.keys });
        }
        return await client.perform("pane.send_text", { pane_id: target(), text });
      }
      case "terminal.keys": {
        const keys = action.keys ?? [];
        if (keys.length === 0 || keys.length > 32 || keys.some((key) => key.length === 0 || key.length > 32)) {
          throw new Error("terminal keys are invalid");
        }
        return await client.perform("pane.send_keys", { pane_id: target(), keys });
      }
      case "terminal.resize":
        return;
      case "agent.message": {
        const text = required(action.text, "text");
        if (Buffer.byteLength(text, "utf8") > 64 * 1024) throw new Error("agent message exceeds 64 KiB");
        await client.perform("agent.send", { target: target(), text });
        return await client.perform("pane.send_keys", { pane_id: target(), keys: ["Enter"] });
      }
      default:
        throw new Error("action type is unsupported");
    }
  }

  private preferredSessionID(): string | null {
    if (this.snapshots.has("default")) return "default";
    return this.snapshots.keys().next().value ?? null;
  }

  private async refresh(): Promise<void> {
    if (this.refreshing) return await this.refreshing;
    this.refreshing = this.refreshNow().finally(() => {
      this.refreshing = null;
    });
    return await this.refreshing;
  }

  private async refreshNow(): Promise<void> {
    const discovered = discoverSessions(this.config.configRoot, this.config.primarySocketPath);
    const activeIDs = new Set(discovered.map((location) => location.id));
    for (const id of this.clients.keys()) {
      if (!activeIDs.has(id)) {
        this.clients.delete(id);
        this.locations.delete(id);
        this.snapshots.delete(id);
        this.eventWatchers.get(id)?.close();
        this.eventWatchers.delete(id);
      }
    }

    const fetched = await Promise.all(discovered.map(async (location): Promise<SessionFetch> => {
      this.locations.set(location.id, location);
      let client = this.clients.get(location.id);
      if (!client || client.socketPath !== location.socketPath) {
        client = new HerdrClient(location.socketPath);
        this.clients.set(location.id, client);
      }
      try {
        const raw = await client.snapshot();
        this.ensureEventWatcher(location.id, raw, client);
        const layoutResults = await Promise.allSettled(raw.tabs.map((tab) => client.exportLayout(tab.tab_id)));
        const layouts = new Map<string, RawLayoutDescription>();
        for (const result of layoutResults) {
          if (result.status === "fulfilled") layouts.set(result.value.tab_id, result.value);
        }
        return { location, raw, layouts };
      } catch (error) {
        console.warn(`[state] ${location.name}: ${error instanceof Error ? error.message : String(error)}`);
        return { location, raw: null, layouts: new Map() };
      }
    }));

    const summaries: SessionSummary[] = fetched.map(({ location, raw }) => ({
      id: location.id,
      name: location.name,
      isDefault: location.isDefault,
      reachable: raw !== null,
    }));

    for (const { location, raw, layouts } of fetched) {
      if (!raw) {
        this.snapshots.delete(location.id);
        continue;
      }
      const snapshot = adaptSnapshot(raw, {
        instance: this.instance,
        activeSessionID: location.id,
        sessions: summaries,
        exportedLayouts: layouts,
        usageMeters: loadUsageMeters(this.config.usageFile),
      });
      const previous = this.snapshots.get(location.id);
      const changed = !previous || snapshotFingerprint(previous) !== snapshotFingerprint(snapshot);
      this.snapshots.set(location.id, snapshot);
      if (changed) for (const listener of this.listeners) listener(snapshot);
    }
  }

  private ensureEventWatcher(sessionID: string, raw: RawHerdrSnapshot, client: HerdrClient) {
    const subscriptions = eventSubscriptions(raw);
    const signature = JSON.stringify(subscriptions);
    const current = this.eventWatchers.get(sessionID);
    if (current?.signature === signature) return;
    current?.close();

    let watcher: EventWatcher;
    const subscription = client.subscribeEvents(subscriptions, {
      onEvent: () => this.scheduleEventRefresh(),
      onClose: (reason) => {
        if (this.eventWatchers.get(sessionID) === watcher) {
          this.eventWatchers.delete(sessionID);
          console.warn(`[events] ${sessionID}: ${reason}`);
        }
      },
    });
    watcher = { signature, close: subscription.close };
    this.eventWatchers.set(sessionID, watcher);
  }

  private scheduleEventRefresh() {
    if (this.eventRefreshTimer) return;
    this.eventRefreshTimer = setTimeout(() => {
      this.eventRefreshTimer = null;
      void this.refresh();
    }, 75);
  }
}

function required<T>(value: T | null | undefined, name: string): T {
  if (value === null || value === undefined || value === "") throw new Error(`${name} is required`);
  return value;
}

function terminalText(action: ActionCommand): string {
  if (action.bytesBase64) return Buffer.from(action.bytesBase64, "base64").toString("utf8");
  return action.text ?? "";
}

function failure(action: ActionCommand, errorCode: string, message: string): ActionResult {
  return { requestID: action.requestID, ok: false, errorCode, message };
}

function snapshotFingerprint(snapshot: BootstrapSnapshot): string {
  return JSON.stringify({ ...snapshot, generatedAtMillis: 0 });
}

function eventSubscriptions(raw: RawHerdrSnapshot): Array<{ type: string; pane_id?: string }> {
  const global: Array<{ type: string; pane_id?: string }> = [
    "workspace.created", "workspace.updated", "workspace.renamed", "workspace.closed", "workspace.focused",
    "worktree.created", "worktree.opened", "worktree.removed",
    "tab.created", "tab.closed", "tab.focused", "tab.renamed",
    "pane.created", "pane.closed", "pane.focused", "pane.moved", "pane.exited", "pane.agent_detected",
  ].map((type) => ({ type }));
  if (compareVersions(raw.version, "0.7.2") >= 0) global.push({ type: "layout.updated" });
  return global.concat(
    raw.panes
      .filter((pane) => pane.agent)
      .map((pane) => ({ type: "pane.agent_status_changed", pane_id: pane.pane_id })),
  );
}

function clampedRatio(value: number): number {
  if (!Number.isFinite(value)) throw new Error("ratio must be finite");
  return Math.max(0.1, Math.min(0.9, value));
}

function herdrMoveDestination(destination: NonNullable<ActionCommand["moveDestination"]>): Record<string, unknown> {
  switch (destination.type) {
    case "tab":
      return {
        type: "tab",
        tab_id: destination.tabID,
        ...(destination.targetPaneID ? { target_pane_id: destination.targetPaneID } : {}),
        split: destination.split,
      };
    case "new_tab":
      return {
        type: "new_tab",
        ...(destination.workspaceID ? { workspace_id: destination.workspaceID } : {}),
        ...(destination.label ? { label: destination.label } : {}),
      };
    case "new_workspace":
      return {
        type: "new_workspace",
        ...(destination.label ? { label: destination.label } : {}),
        ...(destination.tabLabel ? { tab_label: destination.tabLabel } : {}),
      };
  }
}
