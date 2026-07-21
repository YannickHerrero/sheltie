import type { Server, ServerWebSocket } from "bun";
import { AuditLog } from "./audit.ts";
import { AuthenticationError, AuthStore, validateIngress } from "./auth.ts";
import type { BridgeConfig } from "./config.ts";
import type { BridgeStateProviding } from "./state-engine.ts";
import { TerminalFeed } from "./terminal-feed.ts";
import {
  WorkspaceFileError,
  WorkspaceFileStore,
  type StoredWorkspaceFile,
} from "./workspace-files.ts";
import { WorkspaceTodoError, WorkspaceTodoStore, todoDocument, todoErrorDocument } from "./workspace-todos.ts";
import type {
  ActionCommand,
  StreamClientMessage,
  StreamServerMessage,
  NotificationRegistrationRequest,
  TerminalHistoryRequest,
  TerminalSubscription,
  WorkspaceDirectoryListRequest,
  WorkspaceFileDocument,
  WorkspaceFileReadRequest,
  WorkspaceFileSaveRequest,
  WorkspaceTodoReadRequest,
  WorkspaceTodoSaveRequest,
} from "./types.ts";
import { BRIDGE_VERSION, PROTOCOL_VERSION } from "./types.ts";

interface OpenWorkspaceDocument {
  deviceID: string;
  sessionID: string;
  workspaceID: string;
  rootPath: string;
  relativePath: string;
  expiresAtMillis: number;
}

interface WebSocketData {
  deviceID: string;
  expiresAtMillis: number;
  sessionID: string;
  feeds: Map<string, TerminalFeed>;
}

const MAX_TERMINAL_HISTORY_LINES = 1_000;
const MAX_TERMINAL_HISTORY_BYTES = 2 * 1024 * 1024;

const ACTION_TYPES = new Set([
  "workspace.focus", "workspace.create", "workspace.rename", "workspace.close",
  "tab.focus", "tab.create", "tab.rename", "tab.close",
  "pane.focus", "pane.split", "pane.move", "pane.resize", "layout.set_split_ratio", "pane.zoom", "pane.rename", "pane.close",
  "terminal.input", "terminal.keys", "terminal.resize", "agent.message",
]);

const JSON_HEADERS = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
  "content-security-policy": "default-src 'none'; frame-ancestors 'none'",
  "x-content-type-options": "nosniff",
  "referrer-policy": "no-referrer",
};

export interface BridgeServer {
  server: Server<WebSocketData>;
  stop(): void;
}

export function createBridgeServer(
  config: BridgeConfig,
  state: BridgeStateProviding,
  auth: AuthStore,
  audit = new AuditLog(config.dataDirectory),
  todos = new WorkspaceTodoStore(),
  files = new WorkspaceFileStore(),
): BridgeServer {
  const sockets = new Set<ServerWebSocket<WebSocketData>>();
  const openDocuments = new Map<string, OpenWorkspaceDocument>();

  const send = (socket: ServerWebSocket<WebSocketData>, message: StreamServerMessage) => {
    if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
  };

  const removeSnapshotListener = state.addSnapshotListener((snapshot) => {
    for (const socket of sockets) {
      if (socket.data.sessionID === snapshot.activeSessionID) send(socket, { type: "snapshot", snapshot });
    }
  });

  const heartbeat = setInterval(() => {
    const now = Date.now();
    for (const [documentID, document] of openDocuments) {
      if (document.expiresAtMillis <= now) openDocuments.delete(documentID);
    }
    for (const socket of sockets) {
      if (socket.data.expiresAtMillis <= now) {
        socket.close(4001, "session expired");
      } else {
        send(socket, { type: "ping", id: crypto.randomUUID() });
        if (socket.data.expiresAtMillis - now < 2 * 60_000) {
          send(socket, { type: "session.expiring", expiresAtMillis: socket.data.expiresAtMillis });
        }
      }
    }
  }, 30_000);

  const server = Bun.serve<WebSocketData>({
    hostname: config.bindHost,
    port: config.port,
    maxRequestBodySize: 128 * 1024,
    async fetch(request, bunServer) {
      try {
        const url = new URL(request.url);
        const health = () => json({
          ok: true,
          bridgeVersion: BRIDGE_VERSION,
          protocolVersion: PROTOCOL_VERSION,
          herdrReachable: state.hasReachableSession,
        });

        if (
          request.method === "GET" &&
          url.pathname === "/internal/health" &&
          ["127.0.0.1", "localhost", "[::1]"].includes(url.hostname)
        ) {
          return health();
        }

        validateIngress(request, config);
        if (request.method === "GET" && url.pathname === "/v1/health") {
          return health();
        }

        if (request.method === "POST" && url.pathname === "/v1/pair/start") {
          const body = await readJSON(request);
          const result = auth.startPairing(requiredString(body.deviceName), requiredString(body.publicKeyDERBase64));
          return json(result, 201);
        }

        if (request.method === "POST" && url.pathname === "/v1/pair/complete") {
          const body = await readJSON(request);
          const result = auth.completePairing(
            requiredString(body.pairingID),
            requiredString(body.code),
            requiredString(body.signatureDERBase64),
          );
          return json(result, 201);
        }

        if (request.method === "POST" && url.pathname === "/v1/session/refresh") {
          return json(auth.refreshSession(request));
        }

        if (request.method === "GET" && url.pathname === "/v1/bootstrap") {
          auth.authenticateSession(request);
          return json(await state.getSnapshot(url.searchParams.get("session")));
        }

        if (request.method === "POST" && url.pathname === "/v1/actions") {
          const session = auth.authenticateSession(request);
          const action = parseAction(await readJSON(request));
          const result = await state.performAction(action);
          audit.record(session.deviceID, action, result);
          return json(result, result.ok ? 200 : 409);
        }

        if (request.method === "GET" && url.pathname === "/v1/stream") {
          const session = auth.authenticateSession(request);
          const sessionID = url.searchParams.get("session") ?? "default";
          const upgraded = bunServer.upgrade(request, {
            data: {
              deviceID: session.deviceID,
              expiresAtMillis: session.expiresAtMillis,
              sessionID,
              feeds: new Map(),
            },
          });
          return upgraded ? undefined : json({ error: "websocket_upgrade_failed" }, 500);
        }

        return json({ error: "not_found" }, 404);
      } catch (error) {
        return errorResponse(error);
      }
    },
    websocket: {
      open(socket) {
        sockets.add(socket);
        void state.getSnapshot(socket.data.sessionID)
          .then((snapshot) => send(socket, { type: "snapshot", snapshot }))
          .catch((error: unknown) => socket.close(1011, error instanceof Error ? error.message.slice(0, 100) : "snapshot failed"));
      },
      message(socket, raw) {
        void handleWebSocketMessage(socket, raw);
      },
      close(socket) {
        sockets.delete(socket);
        stopFeeds(socket);
      },
    },
  });

  async function handleWebSocketMessage(socket: ServerWebSocket<WebSocketData>, raw: string | Buffer) {
    const messageBytes = Buffer.byteLength(raw);
    if (messageBytes > 2 * 1024 * 1024) {
      socket.close(1009, "message too large");
      return;
    }
    if (socket.data.expiresAtMillis <= Date.now()) {
      socket.close(4001, "session expired");
      return;
    }

    let message: StreamClientMessage;
    try {
      message = JSON.parse(typeof raw === "string" ? raw : raw.toString("utf8")) as StreamClientMessage;
    } catch {
      socket.close(1007, "invalid JSON");
      return;
    }

    if (messageBytes > 512 * 1024 && message.type !== "workspace.file.save") {
      socket.close(1009, "message too large");
      return;
    }

    try {
      switch (message.type) {
        case "subscribe":
          await updateSubscriptions(socket, message.subscriptions);
          break;
        case "terminal.history.request": {
          const request = normalizeHistoryRequest(message.request);
          try {
            const client = state.clientFor(request.sessionID);
            if (!client) throw new Error("Herdr session is unavailable");
            const snapshot = await state.getSnapshot(request.sessionID);
            if (!snapshot.panes.some((pane) => pane.id === request.paneID)) throw new Error("Pane is unavailable");
            const read = await client.readPane(request.paneID, request.lines, "recent");
            const bytes = Buffer.from(read.text, "utf8");
            if (bytes.byteLength > MAX_TERMINAL_HISTORY_BYTES) throw new Error("Terminal history exceeds the bridge limit");
            send(socket, {
              type: "terminal.history",
              history: {
                requestID: request.requestID,
                sessionID: request.sessionID,
                paneID: request.paneID,
                requestedLines: request.lines,
                bytesBase64: bytes.toString("base64"),
                errorMessage: null,
              },
            });
          } catch (error) {
            send(socket, {
              type: "terminal.history",
              history: {
                requestID: request.requestID,
                sessionID: request.sessionID,
                paneID: request.paneID,
                requestedLines: request.lines,
                bytesBase64: null,
                errorMessage: error instanceof Error ? error.message.slice(0, 160) : "Terminal history is unavailable",
              },
            });
          }
          break;
        }
        case "notifications.configure": {
          const request = normalizeNotificationRequest(message.request);
          const saved = auth.configureNotifications(socket.data.deviceID, request);
          send(socket, {
            type: "notifications.configuration",
            configuration: {
              requestID: request.requestID,
              doneEnabled: request.doneEnabled,
              blockedEnabled: request.blockedEnabled,
              providerConfigured: config.apns !== null,
              errorMessage: saved ? null : "Notification settings require a paired device",
            },
          });
          break;
        }
        case "workspace.todo.read": {
          const request = normalizeTodoReadRequest(message.request);
          let document;
          try {
            const snapshot = await state.getSnapshot(request.sessionID);
            const workspace = snapshot.workspaces.find((candidate) => candidate.id === request.workspaceID);
            if (!workspace?.path) throw new WorkspaceTodoError("invalid_workspace_path", "Workspace root is unavailable");
            document = todoDocument(request, todos.read(workspace.path));
          } catch (error) {
            document = todoErrorDocument(request, error);
          }
          send(socket, { type: "workspace.todo", document });
          break;
        }
        case "workspace.todo.save": {
          const request = normalizeTodoSaveRequest(message.request);
          let document;
          try {
            const snapshot = await state.getSnapshot(request.sessionID);
            const workspace = snapshot.workspaces.find((candidate) => candidate.id === request.workspaceID);
            if (!workspace?.path) throw new WorkspaceTodoError("invalid_workspace_path", "Workspace root is unavailable");
            document = todoDocument(request, todos.save(workspace.path, request));
          } catch (error) {
            document = todoErrorDocument(request, error);
          }
          audit.recordOperation(socket.data.deviceID, {
            requestID: request.requestID,
            sessionID: request.sessionID,
            type: "workspace.todo.save",
            targetID: request.workspaceID,
            ok: document.errorCode === null,
            errorCode: document.errorCode,
          });
          send(socket, { type: "workspace.todo", document });
          break;
        }
        case "workspace.directory.list": {
          const request = normalizeDirectoryRequest(message.request);
          try {
            const workspace = await workspaceFor(state, request.sessionID, request.workspaceID);
            const listing = files.list(workspace.path, request.relativePath);
            send(socket, {
              type: "workspace.directory",
              document: {
                ...request,
                ...listing,
                errorCode: null,
                message: null,
              },
            });
          } catch (error) {
            const known = workspaceFileError(error, "The directory is unavailable");
            send(socket, {
              type: "workspace.directory",
              document: {
                ...request,
                entries: [],
                truncated: false,
                errorCode: known.code,
                message: known.message,
              },
            });
          }
          break;
        }
        case "workspace.file.read": {
          const request = normalizeFileReadRequest(message.request);
          try {
            const workspace = await workspaceFor(state, request.sessionID, request.workspaceID);
            const stored = files.read(workspace.path, request.relativePath);
            const documentID = crypto.randomUUID();
            while (openDocuments.size >= 128) {
              const oldest = openDocuments.keys().next().value;
              if (typeof oldest !== "string") break;
              openDocuments.delete(oldest);
            }
            openDocuments.set(documentID, {
              deviceID: socket.data.deviceID,
              sessionID: request.sessionID,
              workspaceID: request.workspaceID,
              rootPath: workspace.path,
              relativePath: request.relativePath,
              expiresAtMillis: Date.now() + 60 * 60_000,
            });
            send(socket, {
              type: "workspace.file",
              document: workspaceFileDocument(request, documentID, stored),
            });
          } catch (error) {
            send(socket, {
              type: "workspace.file",
              document: workspaceFileErrorDocument(request, null, error),
            });
          }
          break;
        }
        case "workspace.file.save": {
          const request = normalizeFileSaveRequest(message.request);
          const open = openDocuments.get(request.documentID);
          if (!open
            || open.deviceID !== socket.data.deviceID
            || open.sessionID !== request.sessionID
            || open.workspaceID !== request.workspaceID
            || open.relativePath !== request.relativePath) {
            const document = workspaceFileErrorDocument(
              request,
              request.documentID,
              new WorkspaceFileError("conflict", "Reopen the file before saving because its editor session expired"),
            );
            audit.recordOperation(socket.data.deviceID, {
              requestID: request.requestID,
              sessionID: request.sessionID,
              type: "workspace.file.save",
              targetID: `${request.workspaceID}:${request.relativePath}`,
              ok: false,
              errorCode: document.errorCode,
            });
            send(socket, { type: "workspace.file", document });
            break;
          }
          let document: WorkspaceFileDocument;
          try {
            const workspace = await workspaceFor(state, open.sessionID, open.workspaceID);
            if (workspace.path !== open.rootPath) {
              throw new WorkspaceFileError("conflict", "The workspace root changed on the Mac");
            }
            const stored = files.save(
              workspace.path,
              open.relativePath,
              decodeBase64(request.contentBase64),
              request.expectedRevision,
              request.force,
            );
            document = workspaceFileDocument(
              { ...open, requestID: request.requestID },
              request.documentID,
              stored,
            );
            open.expiresAtMillis = Date.now() + 60 * 60_000;
          } catch (error) {
            document = workspaceFileErrorDocument(
              { ...open, requestID: request.requestID },
              request.documentID,
              error,
            );
          }
          audit.recordOperation(socket.data.deviceID, {
            requestID: request.requestID,
            sessionID: request.sessionID,
            type: "workspace.file.save",
            targetID: `${open.workspaceID}:${open.relativePath}`,
            ok: document.errorCode === null,
            errorCode: document.errorCode,
          });
          send(socket, { type: "workspace.file", document });
          break;
        }
        case "action": {
          const action = parseAction(message.action as unknown as Record<string, unknown>);
          const result = await state.performAction(action);
          audit.record(socket.data.deviceID, action, result);
          send(socket, { type: "action.result", result });
          break;
        }
        case "resync":
          send(socket, { type: "snapshot", snapshot: await state.getSnapshot(socket.data.sessionID) });
          break;
        case "pong":
          break;
        default:
          socket.close(1008, "unsupported message");
      }
    } catch (error) {
      socket.close(1008, error instanceof Error ? error.message.slice(0, 100) : "invalid message");
    }
  }

  async function updateSubscriptions(socket: ServerWebSocket<WebSocketData>, subscriptions: TerminalSubscription[]) {
    if (!Array.isArray(subscriptions) || subscriptions.length > 8) throw new Error("at most eight terminal subscriptions are allowed");
    stopFeeds(socket);
    for (const raw of subscriptions) {
      const subscription = normalizeSubscription(raw);
      const client = state.clientFor(subscription.sessionID);
      if (!client) throw new Error(`session ${subscription.sessionID} is unavailable`);
      const snapshot = await state.getSnapshot(subscription.sessionID);
      if (!snapshot.panes.some((pane) => pane.id === subscription.paneID)) throw new Error("pane is unavailable");
      const key = `${subscription.sessionID}:${subscription.paneID}`;
      const feed = new TerminalFeed(config, subscription, snapshot.herdr.version, client, (message) => send(socket, message));
      socket.data.feeds.set(key, feed);
      feed.start();
    }
  }

  return {
    server,
    stop() {
      clearInterval(heartbeat);
      removeSnapshotListener();
      for (const socket of sockets) {
        stopFeeds(socket);
        socket.close(1001, "bridge stopping");
      }
      sockets.clear();
      server.stop(true);
    },
  };
}

function stopFeeds(socket: ServerWebSocket<WebSocketData>) {
  for (const feed of socket.data.feeds.values()) feed.stop();
  socket.data.feeds.clear();
}

function normalizeDirectoryRequest(value: WorkspaceDirectoryListRequest): WorkspaceDirectoryListRequest {
  if (!value || typeof value !== "object") throw new Error("workspace directory request is invalid");
  return {
    requestID: requiredString(value.requestID),
    sessionID: requiredString(value.sessionID),
    workspaceID: requiredString(value.workspaceID),
    relativePath: requiredRelativePath(value.relativePath, true),
  };
}

function normalizeFileReadRequest(value: WorkspaceFileReadRequest): WorkspaceFileReadRequest {
  const request = normalizeDirectoryRequest(value);
  if (!request.relativePath) throw new Error("workspace file path is required");
  return request;
}

function normalizeFileSaveRequest(value: WorkspaceFileSaveRequest): WorkspaceFileSaveRequest {
  if (!value || typeof value !== "object") throw new Error("workspace file save request is invalid");
  if (value.expectedRevision !== null && typeof value.expectedRevision !== "string") {
    throw new Error("workspace file revision is invalid");
  }
  return {
    requestID: requiredString(value.requestID),
    sessionID: requiredString(value.sessionID),
    workspaceID: requiredString(value.workspaceID),
    documentID: requiredString(value.documentID),
    relativePath: requiredRelativePath(value.relativePath, false),
    contentBase64: requiredBase64(value.contentBase64),
    expectedRevision: value.expectedRevision,
    force: value.force === true,
  };
}

async function workspaceFor(state: BridgeStateProviding, sessionID: string, workspaceID: string): Promise<{ path: string }> {
  const snapshot = await state.getSnapshot(sessionID);
  const workspace = snapshot.workspaces.find((candidate) => candidate.id === workspaceID);
  if (!workspace?.path) throw new WorkspaceFileError("invalid_workspace_path", "The workspace root is unavailable");
  return { path: workspace.path };
}

function workspaceFileDocument(
  request: { requestID: string; sessionID: string; workspaceID: string; relativePath: string },
  documentID: string,
  stored: StoredWorkspaceFile,
): WorkspaceFileDocument {
  return {
    requestID: request.requestID,
    sessionID: request.sessionID,
    workspaceID: request.workspaceID,
    documentID,
    relativePath: request.relativePath,
    exists: stored.exists,
    contentBase64: stored.bytes.toString("base64"),
    revision: stored.revision,
    modifiedAtMillis: stored.modifiedAtMillis,
    mode: stored.mode,
    errorCode: null,
    message: null,
  };
}

function workspaceFileErrorDocument(
  request: { requestID: string; sessionID: string; workspaceID: string; relativePath: string },
  documentID: string | null,
  error: unknown,
): WorkspaceFileDocument {
  const known = workspaceFileError(error, "The file is unavailable");
  return {
    requestID: request.requestID,
    sessionID: request.sessionID,
    workspaceID: request.workspaceID,
    documentID,
    relativePath: request.relativePath,
    exists: known.latest?.exists ?? false,
    contentBase64: known.latest ? known.latest.bytes.toString("base64") : null,
    revision: known.latest?.revision ?? null,
    modifiedAtMillis: known.latest?.modifiedAtMillis ?? null,
    mode: known.latest?.mode ?? null,
    errorCode: known.code,
    message: known.message,
  };
}

function workspaceFileError(error: unknown, fallback: string): WorkspaceFileError {
  return error instanceof WorkspaceFileError ? error : new WorkspaceFileError("io_error", fallback);
}

function normalizeNotificationRequest(value: NotificationRegistrationRequest): NotificationRegistrationRequest {
  if (!value || typeof value !== "object") throw new Error("notification request is invalid");
  if (value.deviceToken !== null && typeof value.deviceToken !== "string") throw new Error("notification token is invalid");
  return {
    requestID: requiredString(value.requestID),
    deviceToken: value.deviceToken,
    doneEnabled: value.doneEnabled === true,
    blockedEnabled: value.blockedEnabled === true,
  };
}

function normalizeTodoReadRequest(value: WorkspaceTodoReadRequest): WorkspaceTodoReadRequest {
  if (!value || typeof value !== "object") throw new Error("workspace todo request is invalid");
  return {
    requestID: requiredString(value.requestID),
    sessionID: requiredString(value.sessionID),
    workspaceID: requiredString(value.workspaceID),
  };
}

function normalizeTodoSaveRequest(value: WorkspaceTodoSaveRequest): WorkspaceTodoSaveRequest {
  const base = normalizeTodoReadRequest(value);
  if (typeof value.content !== "string") throw new Error("workspace todo content is invalid");
  if (value.expectedRevision !== null && typeof value.expectedRevision !== "string") {
    throw new Error("workspace todo revision is invalid");
  }
  return {
    ...base,
    content: value.content,
    expectedRevision: value.expectedRevision,
    force: value.force === true,
  };
}

function normalizeHistoryRequest(value: TerminalHistoryRequest): TerminalHistoryRequest {
  if (!value || typeof value !== "object") throw new Error("terminal history request is invalid");
  return {
    requestID: requiredString(value.requestID),
    sessionID: requiredString(value.sessionID),
    paneID: requiredString(value.paneID),
    lines: clampInteger(value.lines, 50, MAX_TERMINAL_HISTORY_LINES, MAX_TERMINAL_HISTORY_LINES),
  };
}

function normalizeSubscription(value: TerminalSubscription): TerminalSubscription {
  if (!value || typeof value.sessionID !== "string" || typeof value.paneID !== "string") {
    throw new Error("terminal subscription is invalid");
  }
  return {
    sessionID: value.sessionID,
    paneID: value.paneID,
    columns: clampInteger(value.columns, 20, 400, 120),
    rows: clampInteger(value.rows, 5, 200, 40),
    writable: value.writable === true,
  };
}

function parseAction(value: Record<string, unknown>): ActionCommand {
  const requestID = requiredString(value.requestID);
  const sessionID = requiredString(value.sessionID);
  const type = requiredString(value.type);
  if (!ACTION_TYPES.has(type)) throw new Error("action type is unsupported");
  return { ...value, requestID, sessionID, type } as ActionCommand;
}

async function readJSON(request: Request): Promise<Record<string, unknown>> {
  const text = await request.text();
  if (Buffer.byteLength(text, "utf8") > 128 * 1024) throw new Error("request body is too large");
  const value = JSON.parse(text) as unknown;
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("JSON object is required");
  return value as Record<string, unknown>;
}

function requiredString(value: unknown): string {
  if (typeof value !== "string" || !value.trim()) throw new Error("required string is missing");
  return value;
}

function requiredRelativePath(value: unknown, allowEmpty: boolean): string {
  if (typeof value !== "string" || (!allowEmpty && !value)) throw new Error("relative path is missing");
  return value;
}

function requiredBase64(value: unknown): string {
  if (typeof value !== "string") throw new Error("base64 content is missing");
  const bytes = Buffer.from(value, "base64");
  if (bytes.toString("base64") !== value) throw new Error("base64 content is invalid");
  return value;
}

function decodeBase64(value: string): Buffer {
  return Buffer.from(requiredBase64(value), "base64");
}

function clampInteger(value: unknown, minimum: number, maximum: number, fallback: number): number {
  return typeof value === "number" && Number.isSafeInteger(value)
    ? Math.min(maximum, Math.max(minimum, value))
    : fallback;
}

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: JSON_HEADERS });
}

function errorResponse(error: unknown): Response {
  if (error instanceof AuthenticationError) {
    const status = error.code === "forbidden" ? 403 : error.code === "invalid_pairing" ? 400 : 401;
    return json({ error: error.code, message: error.message }, status);
  }
  if (error instanceof SyntaxError) return json({ error: "invalid_json" }, 400);
  return json({ error: "bad_request", message: error instanceof Error ? error.message : "request failed" }, 400);
}
