import { describe, expect, test } from "bun:test";
import { homedir } from "node:os";
import {
  herdrMoveDestination,
  herdrSplitDirection,
  herdrWorkspaceCreateParameters,
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
