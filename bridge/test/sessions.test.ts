import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { discoverSessions } from "../src/sessions.ts";

let root: string | null = null;
afterEach(() => {
  if (root) rmSync(root, { recursive: true, force: true });
  root = null;
});

describe("session discovery", () => {
  test("discovers the default session first and named sessions alphabetically", () => {
    root = mkdtempSync(join(tmpdir(), "sheltie-sessions-"));
    writeFileSync(join(root, "herdr.sock"), "");
    for (const name of ["zeta", "alpha"]) {
      mkdirSync(join(root, "sessions", name), { recursive: true });
      writeFileSync(join(root, "sessions", name, "herdr.sock"), "");
    }
    mkdirSync(join(root, "sessions", "stopped"), { recursive: true });

    expect(discoverSessions(root, join(root, "herdr.sock"))).toEqual([
      { id: "default", name: "default", socketPath: join(root, "herdr.sock"), isDefault: true },
      { id: "alpha", name: "alpha", socketPath: join(root, "sessions", "alpha", "herdr.sock"), isDefault: false },
      { id: "zeta", name: "zeta", socketPath: join(root, "sessions", "zeta", "herdr.sock"), isDefault: false },
    ]);
  });
});
