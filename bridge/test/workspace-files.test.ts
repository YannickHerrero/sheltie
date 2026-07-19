import { afterEach, expect, test } from "bun:test";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  MAX_WORKSPACE_DIRECTORY_ENTRIES,
  MAX_WORKSPACE_FILE_BYTES,
  WorkspaceFileError,
  WorkspaceFileStore,
} from "../src/workspace-files.ts";

let directory: string | null = null;
afterEach(() => {
  if (directory) rmSync(directory, { recursive: true, force: true });
  directory = null;
});

function root(): string {
  directory = mkdtempSync(join(tmpdir(), "sheltie-files-"));
  return directory;
}

test("lists directories first and omits symbolic links", () => {
  const workspace = root();
  mkdirSync(join(workspace, "Sources"));
  writeFileSync(join(workspace, "README.md"), "hello\n");
  writeFileSync(join(workspace, ".env"), "TOKEN=local\n");
  symlinkSync(join(workspace, "README.md"), join(workspace, "linked.md"));

  const listing = new WorkspaceFileStore().list(workspace, "");

  expect(listing.relativePath).toBe("");
  expect(listing.entries.map((entry) => [entry.kind, entry.name])).toEqual([
    ["directory", "Sources"],
    ["file", ".env"],
    ["file", "README.md"],
  ]);
  expect(listing.truncated).toBeFalse();
});

test("reads, creates, and atomically replaces UTF-8 files while preserving mode", () => {
  const workspace = root();
  mkdirSync(join(workspace, "Sources"));
  const path = join(workspace, "Sources", "tool.sh");
  writeFileSync(path, "#!/bin/sh\necho old\n");
  chmodSync(path, 0o755);
  const store = new WorkspaceFileStore();
  const original = store.read(workspace, "Sources/tool.sh");

  const saved = store.save(
    workspace,
    "Sources/tool.sh",
    Buffer.from("#!/bin/sh\necho new\n"),
    original.revision,
  );
  const created = store.save(workspace, "Sources/new.swift", Buffer.from("let value = 1\n"), null);

  expect(saved.revision).not.toBe(original.revision);
  expect(readFileSync(path, "utf8")).toBe("#!/bin/sh\necho new\n");
  expect(statSync(path).mode & 0o777).toBe(0o755);
  expect(created.exists).toBeTrue();
  expect(readFileSync(join(workspace, "Sources", "new.swift"), "utf8")).toBe("let value = 1\n");
});

test("returns the latest bytes when an external edit conflicts", () => {
  const workspace = root();
  const path = join(workspace, "README.md");
  writeFileSync(path, "original\n");
  const store = new WorkspaceFileStore();
  const original = store.read(workspace, "README.md");
  writeFileSync(path, "external\n");

  try {
    store.save(workspace, "README.md", Buffer.from("mobile\n"), original.revision);
    throw new Error("expected conflict");
  } catch (error) {
    expect(error).toBeInstanceOf(WorkspaceFileError);
    expect((error as WorkspaceFileError).code).toBe("conflict");
    expect((error as WorkspaceFileError).latest?.bytes.toString("utf8")).toBe("external\n");
  }
});

test("rejects path traversal, symbolic links, binary files, and oversized files", () => {
  const workspace = root();
  const outside = join(tmpdir(), `sheltie-outside-${crypto.randomUUID()}.txt`);
  writeFileSync(outside, "outside\n");
  symlinkSync(outside, join(workspace, "linked.txt"));
  writeFileSync(join(workspace, "binary"), Buffer.from([0xff, 0x00]));
  writeFileSync(join(workspace, "large.txt"), Buffer.alloc(MAX_WORKSPACE_FILE_BYTES + 1, 0x61));
  const store = new WorkspaceFileStore();

  try {
    expect(() => store.read(workspace, "../outside.txt")).toThrow();
    expect(() => store.read(workspace, "linked.txt")).toThrow();
    expect(() => store.read(workspace, "binary")).toThrow();
    expect(() => store.read(workspace, "large.txt")).toThrow();
  } finally {
    rmSync(outside, { force: true });
  }
});

test("bounds unusually large directory listings", () => {
  const workspace = root();
  for (let index = 0; index < MAX_WORKSPACE_DIRECTORY_ENTRIES + 2; index += 1) {
    writeFileSync(join(workspace, `file-${String(index).padStart(4, "0")}.txt`), "x");
  }

  const listing = new WorkspaceFileStore().list(workspace, "");

  expect(listing.entries).toHaveLength(MAX_WORKSPACE_DIRECTORY_ENTRIES);
  expect(listing.truncated).toBeTrue();
});
