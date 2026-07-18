import type { Server, ServerWebSocket } from "bun";
import { AuditLog } from "./audit.ts";
import { AuthenticationError, AuthStore, validateIngress } from "./auth.ts";
import type { BridgeConfig } from "./config.ts";
import type { BridgeStateProviding } from "./state-engine.ts";
import { TerminalFeed } from "./terminal-feed.ts";
import type {
  ActionCommand,
  StreamClientMessage,
  StreamServerMessage,
  TerminalSubscription,
} from "./types.ts";
import { BRIDGE_VERSION, PROTOCOL_VERSION } from "./types.ts";

interface WebSocketData {
  deviceID: string;
  expiresAtMillis: number;
  sessionID: string;
  feeds: Map<string, TerminalFeed>;
}

const ACTION_TYPES = new Set([
  "workspace.focus", "workspace.create", "workspace.rename", "workspace.close",
  "tab.focus", "tab.create", "tab.rename", "tab.close",
  "pane.focus", "pane.split", "pane.resize", "pane.zoom", "pane.rename", "pane.close",
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
): BridgeServer {
  const sockets = new Set<ServerWebSocket<WebSocketData>>();

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
        validateIngress(request, config);
        const url = new URL(request.url);

        if (request.method === "GET" && url.pathname === "/v1/health") {
          return json({
            ok: true,
            bridgeVersion: BRIDGE_VERSION,
            protocolVersion: PROTOCOL_VERSION,
            herdrReachable: state.hasReachableSession,
          });
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

    try {
      switch (message.type) {
        case "subscribe":
          await updateSubscriptions(socket, message.subscriptions);
          break;
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
