import { afterEach, describe, expect, test } from "bun:test";
import { rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HerdrClient } from "../src/herdr-client.ts";

let server: ReturnType<typeof Bun.listen> | null = null;
let socketPath: string | null = null;

afterEach(() => {
  server?.stop(true);
  server = null;
  if (socketPath) rmSync(socketPath, { force: true });
  socketPath = null;
});

function startMockHerdr(respond: (request: { id: string; method: string; params: Record<string, unknown> }) => unknown) {
  socketPath = join(tmpdir(), `sheltie-herdr-${crypto.randomUUID()}.sock`);
  server = Bun.listen({
    unix: socketPath,
    socket: {
      data(socket, bytes) {
        const request = JSON.parse(new TextDecoder().decode(bytes).trim()) as {
          id: string;
          method: string;
          params: Record<string, unknown>;
        };
        socket.write(`${JSON.stringify(respond(request))}\n`);
        socket.end();
      },
    },
  });
  return new HerdrClient(socketPath, 1_000);
}

describe("Herdr Unix-socket client", () => {
  test("decodes a one-shot response", async () => {
    const client = startMockHerdr((request) => ({
      id: request.id,
      result: { type: "pong", version: "0.7.3", protocol: 17, capabilities: { live_handoff: true } },
    }));

    expect(await client.ping()).toEqual({ version: "0.7.3", protocol: 17, capabilities: { live_handoff: true } });
  });

  test("falls back to list calls when session.snapshot is unavailable", async () => {
    const client = startMockHerdr((request) => {
      if (request.method === "session.snapshot") {
        return { id: "", error: { code: "invalid_request", message: "unknown variant `session.snapshot`" } };
      }
      const results: Record<string, unknown> = {
        ping: { type: "pong", version: "0.7.1", protocol: 14 },
        "workspace.list": { type: "workspace_list", workspaces: [] },
        "tab.list": { type: "tab_list", tabs: [] },
        "pane.list": { type: "pane_list", panes: [] },
      };
      return { id: request.id, result: results[request.method] };
    });

    expect(await client.snapshot()).toEqual({ version: "0.7.1", protocol: 14, workspaces: [], tabs: [], panes: [] });
  });
});
