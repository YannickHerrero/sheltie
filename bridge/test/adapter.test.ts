import { describe, expect, test } from "bun:test";
import { adaptLayoutNode, adaptSnapshot, compareVersions } from "../src/adapter.ts";
import type { RawHerdrSnapshot } from "../src/types.ts";

const raw: RawHerdrSnapshot = {
  version: "0.7.3",
  protocol: 17,
  workspaces: [
    {
      workspace_id: "w1",
      number: 1,
      label: "herdr",
      focused: true,
      pane_count: 2,
      tab_count: 1,
      active_tab_id: "w1:t1",
      agent_status: "working",
    },
  ],
  tabs: [
    {
      tab_id: "w1:t1",
      workspace_id: "w1",
      number: 1,
      label: "claude",
      focused: true,
      pane_count: 2,
      agent_status: "working",
    },
  ],
  panes: [
    {
      pane_id: "w1:p1",
      terminal_id: "terminal-1",
      workspace_id: "w1",
      tab_id: "w1:t1",
      focused: true,
      cwd: "/Projects/herdr",
      agent: "claude",
      agent_status: "working",
      revision: 2,
    },
    {
      pane_id: "w1:p2",
      terminal_id: "terminal-2",
      workspace_id: "w1",
      tab_id: "w1:t1",
      focused: false,
      cwd: "/Projects/herdr",
      foreground_cwd: "/Projects/herdr/web",
      agent_status: "unknown",
      revision: 3,
    },
  ],
};

describe("Herdr snapshot adapter", () => {
  test("maps Herdr state into protocol v1 and preserves layout", () => {
    const exportedLayouts = new Map([
      [
        "w1:t1",
        {
          workspace_id: "w1",
          tab_id: "w1:t1",
          zoomed: false,
          focused_pane_id: "w1:p1",
          root: {
            type: "split" as const,
            direction: "horizontal" as const,
            ratio: 0.54,
            first: { type: "pane" as const, pane_id: "w1:p1" },
            second: { type: "pane" as const, pane_id: "w1:p2" },
          },
        },
      ],
    ]);
    const snapshot = adaptSnapshot(raw, {
      instance: { id: "studio", name: "Mac Studio", host: "studio.ts.net" },
      activeSessionID: "default",
      sessions: [{ id: "default", name: "default", isDefault: true, reachable: true }],
      exportedLayouts,
      generatedAtMillis: 42,
    });

    expect(snapshot.protocolVersion).toBe(1);
    expect(snapshot.focus).toEqual({ workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1" });
    expect(snapshot.agents[0]).toMatchObject({ name: "claude", displayName: "herdr", status: "working" });
    expect(snapshot.panes[1]).toMatchObject({ kind: "shell", title: "web", cwd: "/Projects/herdr/web" });
    expect(snapshot.layouts[0]?.root).toEqual({
      type: "split",
      direction: "horizontal",
      ratio: 0.54,
      first: { type: "pane", paneID: "w1:p1" },
      second: { type: "pane", paneID: "w1:p2" },
    });
    expect(snapshot.bridge.capabilities).toContain("terminal.history");
    expect(snapshot.bridge.capabilities).toContain("usage.codex");
    expect(snapshot.bridge.capabilities).toContain("workspace.todo");
    expect(snapshot.herdr.capabilities).toContain("terminal.session.observe");
  });

  test("drops empty layout leaves and clamps hostile ratios", () => {
    expect(adaptLayoutNode({ type: "pane" })).toBeNull();
    expect(
      adaptLayoutNode({
        type: "split",
        direction: "vertical",
        ratio: 12,
        first: { type: "pane", pane_id: "left" },
        second: { type: "pane", pane_id: "right" },
      }),
    ).toMatchObject({ type: "split", ratio: 0.9 });
  });

  test("compares semantic versions numerically", () => {
    expect(compareVersions("0.7.10", "0.7.3")).toBe(1);
    expect(compareVersions("v0.7.2", "0.7.2")).toBe(0);
    expect(compareVersions("0.6.9", "0.7.0")).toBe(-1);
  });
});
