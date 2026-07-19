import { createHash, randomUUID } from "node:crypto";
import {
  chmodSync,
  closeSync,
  constants,
  existsSync,
  fsyncSync,
  lstatSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import type { WorkspaceTodoDocument, WorkspaceTodoSaveRequest } from "./types.ts";

export const MAX_WORKSPACE_TODO_BYTES = 256 * 1024;

interface StoredTodo {
  exists: boolean;
  content: string;
  revision: string | null;
  modifiedAtMillis: number | null;
}

export class WorkspaceTodoError extends Error {
  constructor(
    readonly code: "invalid_workspace_path" | "file_too_large" | "invalid_encoding" | "conflict" | "io_error",
    message: string,
    readonly latest?: StoredTodo,
  ) {
    super(message);
    this.name = "WorkspaceTodoError";
  }
}

export class WorkspaceTodoStore {
  read(rootPath: string): StoredTodo {
    const path = todoPath(rootPath);
    if (!existsSync(path)) return { exists: false, content: "", revision: null, modifiedAtMillis: null };
    const info = lstatSync(path);
    if (info.isSymbolicLink() || !info.isFile()) {
      throw new WorkspaceTodoError("invalid_workspace_path", "todo.md must be a regular file inside the workspace root");
    }
    if (info.size > MAX_WORKSPACE_TODO_BYTES) {
      throw new WorkspaceTodoError("file_too_large", "todo.md exceeds the 256 KiB limit");
    }
    const bytes = readFileSync(path);
    let content: string;
    try {
      content = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    } catch {
      throw new WorkspaceTodoError("invalid_encoding", "todo.md must contain valid UTF-8 Markdown");
    }
    return {
      exists: true,
      content,
      revision: revision(bytes),
      modifiedAtMillis: Math.trunc(info.mtimeMs),
    };
  }

  save(rootPath: string, request: WorkspaceTodoSaveRequest): StoredTodo {
    const bytes = Buffer.from(request.content, "utf8");
    if (bytes.byteLength > MAX_WORKSPACE_TODO_BYTES) {
      throw new WorkspaceTodoError("file_too_large", "todo.md exceeds the 256 KiB limit");
    }
    if (request.content.includes("\0")) {
      throw new WorkspaceTodoError("invalid_encoding", "todo.md cannot contain null bytes");
    }

    const path = todoPath(rootPath);
    const before = this.read(rootPath);
    if (!request.force && request.expectedRevision !== before.revision) {
      throw new WorkspaceTodoError("conflict", "todo.md changed on the Mac", before);
    }

    const temporary = join(dirname(path), `.todo.md.sheltie-${randomUUID()}.tmp`);
    let descriptor: number | null = null;
    try {
      descriptor = openSync(
        temporary,
        constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW,
        before.exists ? statSync(path).mode & 0o777 : 0o644,
      );
      writeFileSync(descriptor, bytes);
      fsyncSync(descriptor);
      closeSync(descriptor);
      descriptor = null;

      const latest = this.read(rootPath);
      if (!request.force && latest.revision !== before.revision) {
        throw new WorkspaceTodoError("conflict", "todo.md changed on the Mac", latest);
      }
      renameSync(temporary, path);
      chmodSync(path, before.exists ? statSync(path).mode & 0o777 : 0o644);
      return this.read(rootPath);
    } catch (error) {
      if (error instanceof WorkspaceTodoError) throw error;
      throw new WorkspaceTodoError("io_error", "todo.md could not be saved");
    } finally {
      if (descriptor !== null) closeSync(descriptor);
      rmSync(temporary, { force: true });
    }
  }
}

export function todoDocument(
  request: { requestID: string; sessionID: string; workspaceID: string },
  stored: StoredTodo,
): WorkspaceTodoDocument {
  return {
    ...request,
    exists: stored.exists,
    content: stored.content,
    revision: stored.revision,
    modifiedAtMillis: stored.modifiedAtMillis,
    errorCode: null,
    message: null,
  };
}

export function todoErrorDocument(
  request: { requestID: string; sessionID: string; workspaceID: string },
  error: unknown,
): WorkspaceTodoDocument {
  const known = error instanceof WorkspaceTodoError ? error : new WorkspaceTodoError("io_error", "todo.md is unavailable");
  return {
    ...request,
    exists: known.latest?.exists ?? false,
    content: known.latest?.content ?? null,
    revision: known.latest?.revision ?? null,
    modifiedAtMillis: known.latest?.modifiedAtMillis ?? null,
    errorCode: known.code,
    message: known.message,
  };
}

function todoPath(rootPath: string): string {
  if (!isAbsolute(rootPath)) throw new WorkspaceTodoError("invalid_workspace_path", "Workspace root must be absolute");
  let root: string;
  try {
    root = realpathSync(rootPath);
  } catch {
    throw new WorkspaceTodoError("invalid_workspace_path", "Workspace root is unavailable");
  }
  if (!statSync(root).isDirectory()) throw new WorkspaceTodoError("invalid_workspace_path", "Workspace root is not a directory");
  const path = resolve(root, "todo.md");
  if (dirname(path) !== root) throw new WorkspaceTodoError("invalid_workspace_path", "todo.md escaped the workspace root");
  return path;
}

function revision(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}
