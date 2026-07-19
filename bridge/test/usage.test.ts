import { afterEach, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { collectCodexUsage, loadUsageMeters } from "../src/usage.ts";

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

test("collects the longest Codex rate-limit window without exposing account data", async () => {
  directory = mkdtempSync(join(tmpdir(), "sheltie-codex-usage-"));
  const binary = join(directory, "codex-fixture");
  writeFileSync(binary, `#!/bin/sh
while IFS= read -r line; do
  case "$line" in
    *account/rateLimits/read*)
      printf '%s\\n' '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":200},"secondary":{"usedPercent":41,"windowDurationMins":10080,"resetsAt":300}},"rateLimitsByLimitId":null}}'
      ;;
  esac
done
`);
  chmodSync(binary, 0o755);

  expect(await collectCodexUsage(binary, () => 123_000)).toEqual([{
    id: "codex-weekly",
    provider: "openai",
    label: "Codex · Weekly",
    remainingFraction: 0.59,
    resetAtMillis: 300_000,
    observedAtMillis: 123_000,
  }]);
});

test("rejects the entire untrusted file when a meter is invalid", () => {
  directory = mkdtempSync(join(tmpdir(), "sheltie-usage-"));
  const path = join(directory, "usage.json");
  writeFileSync(path, JSON.stringify([{ id: "bad", provider: "x", label: "Bad", remainingFraction: 2, observedAtMillis: 100 }]));
  expect(loadUsageMeters(path)).toEqual([]);
});
