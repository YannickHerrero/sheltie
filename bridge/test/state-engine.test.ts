import { describe, expect, test } from "bun:test";
import { homedir } from "node:os";
import {
  herdrMoveDestination,
  herdrSplitDirection,
  herdrWorkspaceCreateParameters,
  sendHerdrTerminalKeys,
} from "../src/state-engine.ts";

describe("Herdr structural action translation", () => {
  test("defaults direct workspace creation to the host home", () => {
    expect(herdrWorkspaceCreateParameters({})).toEqual({ cwd: homedir(), focus: true });
    expect(herdrWorkspaceCreateParameters({ cwd: " /tmp/project ", label: " Project " })).toEqual({
      cwd: "/tmp/project",
      label: "Project",
      focus: true,
    });
  });

  test("maps semantic split axes to Herdr placement directions", () => {
    expect(herdrSplitDirection("horizontal")).toBe("right");
    expect(herdrSplitDirection("vertical")).toBe("down");
  });

  test("maps existing-tab move splits to Herdr placement directions", () => {
    expect(herdrMoveDestination({
      type: "tab",
      tabID: "w1:t2",
      targetPaneID: "w1:p3",
      split: "horizontal",
    })).toEqual({
      type: "tab",
      tab_id: "w1:t2",
      target_pane_id: "w1:p3",
      split: "right",
    });
    expect(herdrMoveDestination({
      type: "tab",
      tabID: "w1:t2",
      split: "vertical",
    })).toMatchObject({ split: "down" });
  });
});

describe("Herdr terminal key translation", () => {
  test("encodes paging keys as xterm input instead of unsupported Herdr keys", async () => {
    const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
    await sendHerdrTerminalKeys({
      async perform(method, params) {
        calls.push({ method, params });
      },
    }, "w1:p1", ["PageUp", "PageDown"]);

    expect(calls).toEqual([
      { method: "pane.send_text", params: { pane_id: "w1:p1", text: "\u001b[5~" } },
      { method: "pane.send_text", params: { pane_id: "w1:p1", text: "\u001b[6~" } },
    ]);
  });

  test("preserves key order and xterm modifier encoding around paging keys", async () => {
    const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
    await sendHerdrTerminalKeys({
      async perform(method, params) {
        calls.push({ method, params });
      },
    }, "w1:p2", ["Up", "ctrl+c", "shift+PageUp", "ctrl+alt+shift+PageDown", "Enter"]);

    expect(calls).toEqual([
      { method: "pane.send_keys", params: { pane_id: "w1:p2", keys: ["Up", "ctrl+c"] } },
      { method: "pane.send_text", params: { pane_id: "w1:p2", text: "\u001b[5;2~" } },
      { method: "pane.send_text", params: { pane_id: "w1:p2", text: "\u001b[6;8~" } },
      { method: "pane.send_keys", params: { pane_id: "w1:p2", keys: ["Enter"] } },
    ]);
  });
});
