import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadUsageMeters } from "../src/usage.ts";

let directory: string | null = null;
afterEach(() => {
  if (directory) rmSync(directory, { recursive: true, force: true });
  directory = null;
});

test("loads validated optional provider usage", () => {
  directory = mkdtempSync(join(tmpdir(), "sheltie-usage-"));
  const path = join(directory, "usage.json");
  writeFileSync(path, JSON.stringify([{
    id: "codex-weekly",
    provider: "openai",
    label: "Codex weekly",
    remainingFraction: 0.68,
    resetAtMillis: 123,
    observedAtMillis: 100,
  }]));

  expect(loadUsageMeters(path)).toEqual([{
    id: "codex-weekly",
    provider: "openai",
    label: "Codex weekly",
    remainingFraction: 0.68,
    resetAtMillis: 123,
    observedAtMillis: 100,
  }]);
});

test("rejects the entire untrusted file when a meter is invalid", () => {
  directory = mkdtempSync(join(tmpdir(), "sheltie-usage-"));
  const path = join(directory, "usage.json");
  writeFileSync(path, JSON.stringify([{ id: "bad", provider: "x", label: "Bad", remainingFraction: 2, observedAtMillis: 100 }]));
  expect(loadUsageMeters(path)).toEqual([]);
});
