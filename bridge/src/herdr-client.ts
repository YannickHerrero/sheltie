import type {
  RawHerdrPane,
  RawHerdrSnapshot,
  RawHerdrTab,
  RawHerdrWorkspace,
  RawLayoutDescription,
} from "./types.ts";

interface HerdrErrorEnvelope {
  id?: string;
  error: { code: string; message: string };
}

interface HerdrResultEnvelope<T> {
  id: string;
  result: T;
}

export class HerdrRequestError extends Error {
  constructor(
    readonly method: string,
    readonly code: string,
    message: string,
  ) {
    super(`herdr ${method}: ${code}: ${message}`);
    this.name = "HerdrRequestError";
  }
}

let requestCounter = 0;

export class HerdrClient {
  constructor(
    readonly socketPath: string,
    private readonly timeoutMilliseconds = 5_000,
  ) {}

  async request<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    const id = `sheltie-${++requestCounter}`;

    return await new Promise<T>((resolve, reject) => {
      const decoder = new TextDecoder();
      let buffer = "";
      let socket: Bun.Socket | null = null;
      let finished = false;

      const settle = (callback: () => void) => {
        if (finished) return;
        finished = true;
        clearTimeout(timeout);
        callback();
        try {
          socket?.end();
        } catch {
          // The one-shot Herdr socket may already be closed after its response.
        }
        socket = null;
      };

      const timeout = setTimeout(() => {
        settle(() => reject(new Error(`herdr ${method}: timed out after ${this.timeoutMilliseconds}ms`)));
      }, this.timeoutMilliseconds);

      void Bun.connect({
        unix: this.socketPath,
        socket: {
          open(opened) {
            socket = opened;
            opened.write(`${JSON.stringify({ id, method, params })}\n`);
            opened.flush();
          },
          data(opened, data) {
            socket = opened;
            buffer += decoder.decode(data, { stream: true });
            const newline = buffer.indexOf("\n");
            if (newline === -1) return;
            const line = buffer.slice(0, newline);
            settle(() => {
              try {
                const envelope = JSON.parse(line) as HerdrResultEnvelope<T> | HerdrErrorEnvelope;
                if ("error" in envelope) {
                  reject(new HerdrRequestError(method, envelope.error.code, envelope.error.message));
                } else {
                  resolve(envelope.result);
                }
              } catch (error) {
                reject(error);
              }
            });
          },
          error(_socket, error) {
            settle(() => reject(error));
          },
          close() {
            settle(() => reject(new Error(`herdr ${method}: connection closed before a response`)));
          },
        },
      }).catch((error: unknown) => settle(() => reject(error)));
    });
  }

  async ping(): Promise<{ version: string; protocol: number; capabilities: Record<string, boolean> }> {
    const result = await this.request<{
      type: "pong";
      version: string;
      protocol: number;
      capabilities?: Record<string, boolean>;
    }>("ping");
    return { version: result.version, protocol: result.protocol, capabilities: result.capabilities ?? {} };
  }

  async snapshot(): Promise<RawHerdrSnapshot> {
    try {
      const result = await this.request<{ type: "session_snapshot"; snapshot: RawHerdrSnapshot }>("session.snapshot");
      return result.snapshot;
    } catch (error) {
      if (!(error instanceof HerdrRequestError) || !error.message.includes("unknown variant `session.snapshot`")) {
        throw error;
      }
      const [server, workspaceResult, tabResult, paneResult] = await Promise.all([
        this.ping(),
        this.request<{ type: "workspace_list"; workspaces: RawHerdrWorkspace[] }>("workspace.list"),
        this.request<{ type: "tab_list"; tabs: RawHerdrTab[] }>("tab.list"),
        this.request<{ type: "pane_list"; panes: RawHerdrPane[] }>("pane.list"),
      ]);
      return {
        version: server.version,
        protocol: server.protocol,
        workspaces: workspaceResult.workspaces,
        tabs: tabResult.tabs,
        panes: paneResult.panes,
      };
    }
  }

  subscribeEvents(
    subscriptions: Array<{ type: string; pane_id?: string }>,
    handlers: { onEvent: (event: string) => void; onClose: (reason: string) => void },
  ): { close(): void } {
    const id = `sheltie-events-${++requestCounter}`;
    const decoder = new TextDecoder();
    let buffer = "";
    let socket: Bun.Socket | null = null;
    let closed = false;
    let acknowledged = false;

    const finish = (reason: string, notify: boolean) => {
      if (closed) return;
      closed = true;
      clearTimeout(timeout);
      try { socket?.end(); } catch { /* already closed */ }
      socket = null;
      if (notify) handlers.onClose(reason);
    };
    const consume = (line: string) => {
      let value: unknown;
      try { value = JSON.parse(line); } catch { return finish("invalid event JSON", true); }
      if (!value || typeof value !== "object") return;
      const message = value as Record<string, unknown>;
      if (message.error && typeof message.error === "object") {
        const error = message.error as Record<string, unknown>;
        return finish(`${String(error.code)}: ${String(error.message)}`, true);
      }
      if (typeof message.event === "string") {
        handlers.onEvent(message.event);
      } else if (message.result) {
        acknowledged = true;
        clearTimeout(timeout);
      }
    };
    const timeout = setTimeout(() => finish("event subscription acknowledgement timed out", true), this.timeoutMilliseconds);

    void Bun.connect({
      unix: this.socketPath,
      socket: {
        open(opened) {
          socket = opened;
          opened.write(`${JSON.stringify({ id, method: "events.subscribe", params: { subscriptions } })}\n`);
          opened.flush();
        },
        data(opened, data) {
          socket = opened;
          buffer += decoder.decode(data, { stream: true });
          let newline = buffer.indexOf("\n");
          while (newline >= 0 && !closed) {
            const line = buffer.slice(0, newline).trim();
            buffer = buffer.slice(newline + 1);
            if (line) consume(line);
            newline = buffer.indexOf("\n");
          }
        },
        error(_socket, error) { finish(error.message, true); },
        close() { finish(acknowledged ? "event stream closed" : "event stream closed before acknowledgement", true); },
      },
    }).catch((error: unknown) => finish(error instanceof Error ? error.message : String(error), true));

    return { close: () => finish("closed", false) };
  }

  async exportLayout(tabID: string): Promise<RawLayoutDescription> {
    const result = await this.request<{ type: "layout_export"; layout: RawLayoutDescription }>("layout.export", {
      tab_id: tabID,
    });
    return result.layout;
  }

  async readPane(paneID: string, lines = 200): Promise<{ text: string; revision: number; truncated: boolean }> {
    const result = await this.request<{
      type: "pane_read";
      read: { text: string; revision: number; truncated: boolean };
    }>("pane.read", {
      pane_id: paneID,
      source: "visible",
      lines,
      format: "ansi",
      strip_ansi: false,
    });
    return result.read;
  }

  async focusPane(paneID: string): Promise<void> {
    // Herdr has no direct pane.focus RPC. Agent panes accept their legacy pane ID as an
    // agent.focus target; plain shell panes need their tab activated first.
    try {
      await this.request<unknown>("agent.focus", { target: paneID });
      return;
    } catch (error) {
      if (!(error instanceof HerdrRequestError) || error.code !== "agent_not_found") throw error;
    }

    const pane = await this.request<{ type: "pane_info"; pane: RawHerdrPane }>("pane.get", { pane_id: paneID });
    await this.request<unknown>("tab.focus", { tab_id: pane.pane.tab_id });
    const current = await this.request<{ type: "pane_current"; pane: RawHerdrPane }>("pane.current");
    if (current.pane.pane_id === paneID) return;

    const opposite = { left: "right", right: "left", up: "down", down: "up" } as const;
    for (const direction of Object.keys(opposite) as Array<keyof typeof opposite>) {
      const result = await this.request<{
        type: "pane_neighbor";
        neighbor: { pane_id: string };
      }>("pane.neighbor", { pane_id: paneID, direction });
      if (result.neighbor.pane_id === paneID) continue;
      await this.request<unknown>("pane.focus_direction", {
        pane_id: result.neighbor.pane_id,
        direction: opposite[direction],
      });
      return;
    }

    throw new Error(`herdr could not focus pane ${paneID}`);
  }

  async perform(method: string, params: Record<string, unknown>): Promise<void> {
    await this.request<unknown>(method, params);
  }
}
