import type { HerdrLayoutDirection, SplitDirection } from "./types.ts";

export function protocolSplitDirection(direction: HerdrLayoutDirection): SplitDirection {
  switch (direction) {
    case "right":
    case "horizontal":
      return "horizontal";
    case "down":
    case "vertical":
      return "vertical";
    default:
      throw new Error(`unsupported Herdr split direction: ${String(direction)}`);
  }
}

export function herdrSplitDirection(direction: SplitDirection): "right" | "down" {
  switch (direction) {
    case "horizontal":
      return "right";
    case "vertical":
      return "down";
  }
}
