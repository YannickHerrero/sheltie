import { describe, expect, test } from "bun:test";
import { herdrMoveDestination, herdrSplitDirection } from "../src/state-engine.ts";

describe("Herdr structural action translation", () => {
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
