export const PROTOCOL_VERSION = 1;
export const BRIDGE_VERSION = "0.1.0";

export type AgentStatus = "idle" | "working" | "blocked" | "done" | "unknown";
export type PaneKind = "agent" | "shell";
export type SplitDirection = "horizontal" | "vertical";
export type PaneDirection = "left" | "right" | "up" | "down";

export interface BridgeInfo {
  version: string;
  protocolVersion: number;
  capabilities: string[];
}

export interface InstanceInfo {
  id: string;
  name: string;
  host: string;
}

export interface HerdrInfo {
  version: string;
  protocolVersion: number;
  capabilities: string[];
}

export interface SessionSummary {
  id: string;
  name: string;
  isDefault: boolean;
  reachable: boolean;
}

export interface WorkspaceSnapshot {
  id: string;
  number: number;
  label: string;
  path: string | null;
  branch: string | null;
  activeTabID: string | null;
  paneCount: number;
  tabCount: number;
  status: AgentStatus;
  focused: boolean;
}

export interface TabSnapshot {
  id: string;
  workspaceID: string;
  number: number;
  label: string;
  paneCount: number;
  status: AgentStatus;
  focused: boolean;
}

export interface PaneSnapshot {
  id: string;
  terminalID: string;
  workspaceID: string;
  tabID: string;
  title: string;
  cwd: string;
  kind: PaneKind;
  agentName: string | null;
  agentDisplayName: string | null;
  agentStatus: AgentStatus;
  focused: boolean;
  revision: number;
}

export interface AgentSnapshot {
  id: string;
  paneID: string;
  workspaceID: string;
  tabID: string;
  name: string;
  displayName: string;
  status: AgentStatus;
  statusLabel: string | null;
}

export type LayoutNode =
  | { type: "pane"; paneID: string }
  | {
      type: "split";
      direction: SplitDirection;
      ratio: number;
      first: LayoutNode;
      second: LayoutNode;
    };

export interface PaneLayoutSnapshot {
  workspaceID: string;
  tabID: string;
  zoomed: boolean;
  focusedPaneID: string | null;
  root: LayoutNode;
}

export interface UsageMeter {
  id: string;
  provider: string;
  label: string;
  remainingFraction: number;
  resetAtMillis: number | null;
  observedAtMillis: number;
}

export interface BootstrapSnapshot {
  protocolVersion: number;
  bridge: BridgeInfo;
  instance: InstanceInfo;
  herdr: HerdrInfo;
  sessions: SessionSummary[];
  activeSessionID: string | null;
  workspaces: WorkspaceSnapshot[];
  tabs: TabSnapshot[];
  panes: PaneSnapshot[];
  agents: AgentSnapshot[];
  layouts: PaneLayoutSnapshot[];
  focus: { workspaceID: string | null; tabID: string | null; paneID: string | null };
  usageMeters: UsageMeter[];
  generatedAtMillis: number;
}

export interface TerminalSubscription {
  sessionID: string;
  paneID: string;
  columns: number;
  rows: number;
  writable: boolean;
}

export interface TerminalHistoryRequest {
  requestID: string;
  sessionID: string;
  paneID: string;
  lines: number;
}

export interface TerminalHistory {
  requestID: string;
  sessionID: string;
  paneID: string;
  requestedLines: number;
  bytesBase64: string | null;
  errorMessage: string | null;
}

export interface WorkspaceTodoReadRequest {
  requestID: string;
  sessionID: string;
  workspaceID: string;
}

export interface WorkspaceTodoSaveRequest extends WorkspaceTodoReadRequest {
  content: string;
  expectedRevision: string | null;
  force: boolean;
}

export interface WorkspaceTodoDocument extends WorkspaceTodoReadRequest {
  exists: boolean;
  content: string | null;
  revision: string | null;
  modifiedAtMillis: number | null;
  errorCode: string | null;
  message: string | null;
}

export type WorkspaceFileKind = "directory" | "file";

export interface WorkspaceFileEntry {
  name: string;
  relativePath: string;
  kind: WorkspaceFileKind;
  size: number | null;
  modifiedAtMillis: number;
}

export interface WorkspaceDirectoryListRequest {
  requestID: string;
  sessionID: string;
  workspaceID: string;
  relativePath: string;
}

export interface WorkspaceDirectoryListing extends WorkspaceDirectoryListRequest {
  entries: WorkspaceFileEntry[];
  truncated: boolean;
  errorCode: string | null;
  message: string | null;
}

export interface WorkspaceFileReadRequest extends WorkspaceDirectoryListRequest {}

export interface WorkspaceFileSaveRequest {
  requestID: string;
  sessionID: string;
  workspaceID: string;
  documentID: string;
  relativePath: string;
  contentBase64: string;
  expectedRevision: string | null;
  force: boolean;
}

export interface WorkspaceFileDocument {
  requestID: string;
  sessionID: string;
  workspaceID: string;
  documentID: string | null;
  relativePath: string;
  exists: boolean;
  contentBase64: string | null;
  revision: string | null;
  modifiedAtMillis: number | null;
  mode: number | null;
  errorCode: string | null;
  message: string | null;
}

export interface NotificationRegistrationRequest {
  requestID: string;
  deviceToken: string | null;
  doneEnabled: boolean;
  blockedEnabled: boolean;
}

export interface NotificationConfiguration {
  requestID: string;
  doneEnabled: boolean;
  blockedEnabled: boolean;
  providerConfigured: boolean;
  errorMessage: string | null;
}

export interface TerminalFrame {
  sessionID: string;
  paneID: string;
  sequence: number;
  full: boolean;
  columns: number;
  rows: number;
  bytesBase64: string;
}

export type ActionType =
  | "workspace.focus"
  | "workspace.create"
  | "workspace.rename"
  | "workspace.close"
  | "tab.focus"
  | "tab.create"
  | "tab.rename"
  | "tab.close"
  | "pane.focus"
  | "pane.split"
  | "pane.move"
  | "pane.resize"
  | "layout.set_split_ratio"
  | "pane.zoom"
  | "pane.rename"
  | "pane.close"
  | "terminal.input"
  | "terminal.keys"
  | "terminal.resize"
  | "agent.message";

export type PaneMoveDestination =
  | { type: "tab"; tabID: string; targetPaneID?: string | null; split: SplitDirection }
  | { type: "new_tab"; workspaceID?: string | null; label?: string | null }
  | { type: "new_workspace"; label?: string | null; tabLabel?: string | null };

export interface ActionCommand {
  requestID: string;
  sessionID: string;
  type: ActionType;
  targetID?: string | null;
  text?: string | null;
  bytesBase64?: string | null;
  keys?: string[] | null;
  splitDirection?: SplitDirection | null;
  paneDirection?: PaneDirection | null;
  ratio?: number | null;
  splitPath?: boolean[] | null;
  moveDestination?: PaneMoveDestination | null;
  label?: string | null;
  cwd?: string | null;
  columns?: number | null;
  rows?: number | null;
}

export interface ActionResult {
  requestID: string;
  ok: boolean;
  errorCode: string | null;
  message: string | null;
}

export type StreamServerMessage =
  | { type: "snapshot"; snapshot: BootstrapSnapshot }
  | { type: "terminal.frame"; frame: TerminalFrame }
  | { type: "terminal.history"; history: TerminalHistory }
  | { type: "workspace.todo"; document: WorkspaceTodoDocument }
  | { type: "workspace.directory"; document: WorkspaceDirectoryListing }
  | { type: "workspace.file"; document: WorkspaceFileDocument }
  | { type: "notifications.configuration"; configuration: NotificationConfiguration }
  | { type: "terminal.closed"; terminal: { sessionID: string; paneID: string; reason: string } }
  | { type: "action.result"; result: ActionResult }
  | { type: "session.expiring"; expiresAtMillis: number }
  | { type: "ping"; id: string };

export type StreamClientMessage =
  | { type: "subscribe"; subscriptions: TerminalSubscription[] }
  | { type: "terminal.history.request"; request: TerminalHistoryRequest }
  | { type: "workspace.todo.read"; request: WorkspaceTodoReadRequest }
  | { type: "workspace.todo.save"; request: WorkspaceTodoSaveRequest }
  | { type: "workspace.directory.list"; request: WorkspaceDirectoryListRequest }
  | { type: "workspace.file.read"; request: WorkspaceFileReadRequest }
  | { type: "workspace.file.save"; request: WorkspaceFileSaveRequest }
  | { type: "notifications.configure"; request: NotificationRegistrationRequest }
  | { type: "action"; action: ActionCommand }
  | { type: "resync" }
  | { type: "pong"; id: string };

export interface RawHerdrWorkspace {
  workspace_id: string;
  number: number;
  label: string;
  focused: boolean;
  pane_count: number;
  tab_count: number;
  active_tab_id?: string | null;
  agent_status: AgentStatus;
  worktree?: { checkout_path: string } | null;
}

export interface RawHerdrTab {
  tab_id: string;
  workspace_id: string;
  number: number;
  label: string;
  focused: boolean;
  pane_count: number;
  agent_status: AgentStatus;
}

export interface RawHerdrPane {
  pane_id: string;
  terminal_id: string;
  workspace_id: string;
  tab_id: string;
  focused: boolean;
  cwd: string;
  foreground_cwd?: string | null;
  label?: string | null;
  title?: string | null;
  agent?: string | null;
  display_agent?: string | null;
  agent_status: AgentStatus;
  custom_status?: string | null;
  revision: number;
}

export type RawLayoutNode =
  | { type: "pane"; pane_id?: string | null; label?: string | null; cwd?: string | null }
  | {
      type: "split";
      direction: SplitDirection;
      ratio: number;
      first: RawLayoutNode;
      second: RawLayoutNode;
    };

export interface RawLayoutDescription {
  workspace_id: string;
  tab_id: string;
  zoomed: boolean;
  focused_pane_id?: string | null;
  root: RawLayoutNode;
}

export interface RawHerdrSnapshot {
  version: string;
  protocol: number;
  workspaces: RawHerdrWorkspace[];
  tabs: RawHerdrTab[];
  panes: RawHerdrPane[];
}
