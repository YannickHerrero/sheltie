import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { MAX_WORKSPACE_TODO_BYTES, WorkspaceTodoError, WorkspaceTodoStore } from "../src/workspace-todos.ts";

let directory: string | null = null;
afterEach(() => {
  if (directory) rmSync(directory, { recursive: true, force: true });
  directory = null;
});

function root(): string {
  directory = mkdtempSync(join(tmpdir(), "sheltie-todos-"));
  return directory;
}

test("reads a missing todo and saves Markdown atomically", () => {
  const workspace = root();
  const store = new WorkspaceTodoStore();
  expect(store.read(workspace)).toMatchObject({ exists: false, content: "", revision: null });

  const saved = store.save(workspace, {
    requestID: "save-1",
    sessionID: "default",
    workspaceID: "w1",
    content: "- [ ] Ship it\n",
    expectedRevision: null,
    force: false,
  });

  expect(saved.exists).toBe(true);
  expect(saved.revision).not.toBeNull();
  expect(readFileSync(join(workspace, "todo.md"), "utf8")).toBe("- [ ] Ship it\n");
});

test("detects external edits and returns the latest document", () => {
  const workspace = root();
  const store = new WorkspaceTodoStore();
  writeFileSync(join(workspace, "todo.md"), "original\n");
  const original = store.read(workspace);
  writeFileSync(join(workspace, "todo.md"), "external\n");

  try {
    store.save(workspace, {
      requestID: "save-2",
      sessionID: "default",
      workspaceID: "w1",
      content: "mobile\n",
      expectedRevision: original.revision,
      force: false,
    });
    throw new Error("expected conflict");
  } catch (error) {
    expect(error).toBeInstanceOf(WorkspaceTodoError);
    expect((error as WorkspaceTodoError).code).toBe("conflict");
    expect((error as WorkspaceTodoError).latest?.content).toBe("external\n");
  }
});

test("rejects symlinks and oversized todo files", () => {
  const workspace = root();
  const store = new WorkspaceTodoStore();
  const outside = join(tmpdir(), `sheltie-outside-${crypto.randomUUID()}.md`);
  writeFileSync(outside, "private\n");
  symlinkSync(outside, join(workspace, "todo.md"));
  try {
    expect(() => store.read(workspace)).toThrow();
  } finally {
    rmSync(outside, { force: true });
  }

  rmSync(join(workspace, "todo.md"), { force: true });
  expect(() => store.save(workspace, {
    requestID: "save-3",
    sessionID: "default",
    workspaceID: "w1",
    content: "x".repeat(MAX_WORKSPACE_TODO_BYTES + 1),
    expectedRevision: null,
    force: false,
  })).toThrow();
});
