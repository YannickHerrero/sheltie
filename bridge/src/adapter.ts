import { basename } from "node:path";
import type {
  BootstrapSnapshot,
  InstanceInfo,
  LayoutNode,
  PaneLayoutSnapshot,
  RawHerdrPane,
  RawHerdrSnapshot,
  RawLayoutDescription,
  RawLayoutNode,
  SessionSummary,
  UsageMeter,
} from "./types.ts";
import { BRIDGE_VERSION, PROTOCOL_VERSION } from "./types.ts";

function displayAgentName(agent: string): string {
  const labels: Record<string, string> = {
    claude: "Claude Code",
    codex: "Codex",
    opencode: "OpenCode",
    pi: "Pi",
    copilot: "GitHub Copilot",
  };
  return labels[agent.toLowerCase()] ?? agent;
}

function paneTitle(pane: RawHerdrPane): string {
  if (pane.display_agent) return pane.display_agent;
  if (pane.agent) return displayAgentName(pane.agent);
  if (pane.title) return pane.title;
  if (pane.label) return pane.label;
  return basename(pane.foreground_cwd ?? pane.cwd) || "shell";
}

export function adaptLayoutNode(node: RawLayoutNode): LayoutNode | null {
  if (node.type === "pane") {
    return node.pane_id ? { type: "pane", paneID: node.pane_id } : null;
  }
  const first = adaptLayoutNode(node.first);
  const second = adaptLayoutNode(node.second);
  if (!first || !second) return first ?? second;
  return {
    type: "split",
    direction: node.direction,
    ratio: Math.min(0.9, Math.max(0.1, node.ratio)),
    first,
    second,
  };
}

export function adaptLayout(layout: RawLayoutDescription): PaneLayoutSnapshot | null {
  const root = adaptLayoutNode(layout.root);
  if (!root) return null;
  return {
    workspaceID: layout.workspace_id,
    tabID: layout.tab_id,
    zoomed: layout.zoomed,
    focusedPaneID: layout.focused_pane_id ?? null,
    root,
  };
}

function fallbackLayout(raw: RawHerdrSnapshot, tabID: string): PaneLayoutSnapshot | null {
  const panes = raw.panes.filter((pane) => pane.tab_id === tabID);
  const first = panes[0];
  if (!first) return null;
  let root: LayoutNode = { type: "pane", paneID: first.pane_id };
  for (const pane of panes.slice(1)) {
    root = {
      type: "split",
      direction: "horizontal",
      ratio: 0.5,
      first: root,
      second: { type: "pane", paneID: pane.pane_id },
    };
  }
  return {
    workspaceID: first.workspace_id,
    tabID,
    zoomed: false,
    focusedPaneID: panes.find((pane) => pane.focused)?.pane_id ?? first.pane_id,
    root,
  };
}

export interface AdaptSnapshotContext {
  instance: InstanceInfo;
  activeSessionID: string;
  sessions: SessionSummary[];
  exportedLayouts: Map<string, RawLayoutDescription>;
  usageMeters?: UsageMeter[];
  generatedAtMillis?: number;
}

export function adaptSnapshot(raw: RawHerdrSnapshot, context: AdaptSnapshotContext): BootstrapSnapshot {
  const firstPaneByWorkspace = new Map<string, RawHerdrPane>();
  for (const pane of raw.panes) {
    if (!firstPaneByWorkspace.has(pane.workspace_id)) firstPaneByWorkspace.set(pane.workspace_id, pane);
  }

  const panes = raw.panes.map((pane) => ({
    id: pane.pane_id,
    terminalID: pane.terminal_id,
    workspaceID: pane.workspace_id,
    tabID: pane.tab_id,
    title: paneTitle(pane),
    cwd: pane.foreground_cwd ?? pane.cwd,
    kind: pane.agent ? ("agent" as const) : ("shell" as const),
    agentName: pane.agent ?? null,
    agentDisplayName: pane.agent ? paneTitle(pane) : null,
    agentStatus: pane.agent_status,
    focused: pane.focused,
    revision: pane.revision,
  }));

  const layouts = raw.tabs.flatMap((tab) => {
    const exported = context.exportedLayouts.get(tab.tab_id);
    const layout = exported ? adaptLayout(exported) : fallbackLayout(raw, tab.tab_id);
    return layout ? [layout] : [];
  });

  const focusedPane = raw.panes.find((pane) => pane.focused) ?? null;
  const focusedTab = raw.tabs.find((tab) => tab.focused) ?? (focusedPane ? raw.tabs.find((tab) => tab.tab_id === focusedPane.tab_id) : null);
  const focusedWorkspace = raw.workspaces.find((workspace) => workspace.focused)
    ?? (focusedPane ? raw.workspaces.find((workspace) => workspace.workspace_id === focusedPane.workspace_id) : null);

  const capabilities = ["snapshots", "actions", "terminal.poll"];
  if (compareVersions(raw.version, "0.7.2") >= 0) {
    capabilities.push("session.snapshot", "terminal.session.observe");
  }

  return {
    protocolVersion: PROTOCOL_VERSION,
    bridge: {
      version: BRIDGE_VERSION,
      protocolVersion: PROTOCOL_VERSION,
      capabilities: ["pairing", "snapshots", "actions", "terminal.stream", "terminal.history", "multi-session"],
    },
    instance: context.instance,
    herdr: {
      version: raw.version,
      protocolVersion: raw.protocol,
      capabilities,
    },
    sessions: context.sessions,
    activeSessionID: context.activeSessionID,
    workspaces: raw.workspaces.map((workspace) => ({
      id: workspace.workspace_id,
      number: workspace.number,
      label: workspace.label,
      path: firstPaneByWorkspace.get(workspace.workspace_id)?.cwd ?? null,
      branch: null,
      activeTabID: workspace.active_tab_id ?? null,
      paneCount: workspace.pane_count,
      tabCount: workspace.tab_count,
      status: workspace.agent_status,
      focused: workspace.focused,
    })),
    tabs: raw.tabs.map((tab) => ({
      id: tab.tab_id,
      workspaceID: tab.workspace_id,
      number: tab.number,
      label: tab.label,
      paneCount: tab.pane_count,
      status: tab.agent_status,
      focused: tab.focused,
    })),
    panes,
    agents: raw.panes.flatMap((pane) => {
      if (!pane.agent) return [];
      const workspace = raw.workspaces.find((candidate) => candidate.workspace_id === pane.workspace_id);
      return [{
        id: pane.pane_id,
        paneID: pane.pane_id,
        workspaceID: pane.workspace_id,
        tabID: pane.tab_id,
        name: pane.agent,
        displayName: workspace?.label ?? paneTitle(pane),
        status: pane.agent_status,
        statusLabel: pane.custom_status ?? `${pane.agent_status} · ${pane.agent}`,
      }];
    }),
    layouts,
    focus: {
      workspaceID: focusedWorkspace?.workspace_id ?? null,
      tabID: focusedTab?.tab_id ?? null,
      paneID: focusedPane?.pane_id ?? null,
    },
    usageMeters: context.usageMeters ?? [],
    generatedAtMillis: context.generatedAtMillis ?? Date.now(),
  };
}

export function compareVersions(left: string, right: string): number {
  const normalize = (value: string) => value.replace(/^v/, "").split(".").map((part) => Number.parseInt(part, 10) || 0);
  const a = normalize(left);
  const b = normalize(right);
  for (let index = 0; index < Math.max(a.length, b.length); index += 1) {
    const difference = (a[index] ?? 0) - (b[index] ?? 0);
    if (difference !== 0) return Math.sign(difference);
  }
  return 0;
}
