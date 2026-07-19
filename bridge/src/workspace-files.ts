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
  readdirSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { isAbsolute, join, sep } from "node:path";

export const MAX_WORKSPACE_FILE_BYTES = 1024 * 1024;
export const MAX_WORKSPACE_DIRECTORY_ENTRIES = 500;

export type WorkspaceFileErrorCode =
  | "invalid_workspace_path"
  | "invalid_relative_path"
  | "not_text_file"
  | "file_too_large"
  | "invalid_encoding"
  | "conflict"
  | "io_error";

export interface StoredWorkspaceFile {
  exists: boolean;
  bytes: Buffer;
  revision: string | null;
  modifiedAtMillis: number | null;
  mode: number | null;
}

export interface WorkspaceFileEntry {
  name: string;
  relativePath: string;
  kind: "directory" | "file";
  size: number | null;
  modifiedAtMillis: number;
}

export interface WorkspaceDirectoryListing {
  relativePath: string;
  entries: WorkspaceFileEntry[];
  truncated: boolean;
}

export class WorkspaceFileError extends Error {
  constructor(
    readonly code: WorkspaceFileErrorCode,
    message: string,
    readonly latest?: StoredWorkspaceFile,
  ) {
    super(message);
    this.name = "WorkspaceFileError";
  }
}

export class WorkspaceFileStore {
  list(rootPath: string, relativePath: string): WorkspaceDirectoryListing {
    const root = workspaceRoot(rootPath);
    const normalized = normalizeRelativePath(relativePath, true);
    const directory = resolveWorkspacePath(root, normalized, false);
    const directoryInfo = lstatSync(directory);
    if (!directoryInfo.isDirectory()) {
      throw new WorkspaceFileError("invalid_relative_path", "The selected path is not a directory");
    }

    const entries = readdirSync(directory)
      .flatMap((name): WorkspaceFileEntry[] => {
        const path = join(directory, name);
        const info = lstatSync(path);
        if (info.isSymbolicLink()) return [];
        const kind = info.isDirectory() ? "directory" : info.isFile() ? "file" : null;
        if (!kind) return [];
        return [{
          name,
          relativePath: normalized ? `${normalized}/${name}` : name,
          kind,
          size: kind === "file" ? info.size : null,
          modifiedAtMillis: Math.trunc(info.mtimeMs),
        }];
      })
      .sort((left, right) => {
        if (left.kind !== right.kind) return left.kind === "directory" ? -1 : 1;
        return left.name.localeCompare(right.name, undefined, { sensitivity: "base" });
      });

    return {
      relativePath: normalized,
      entries: entries.slice(0, MAX_WORKSPACE_DIRECTORY_ENTRIES),
      truncated: entries.length > MAX_WORKSPACE_DIRECTORY_ENTRIES,
    };
  }

  read(rootPath: string, relativePath: string): StoredWorkspaceFile {
    const root = workspaceRoot(rootPath);
    const normalized = normalizeRelativePath(relativePath, false);
    const path = resolveWorkspacePath(root, normalized, true);
    if (!existsSync(path)) {
      return { exists: false, bytes: Buffer.alloc(0), revision: null, modifiedAtMillis: null, mode: null };
    }

    const info = lstatSync(path);
    if (info.isSymbolicLink() || !info.isFile()) {
      throw new WorkspaceFileError("not_text_file", "The selected path must be a regular file");
    }
    if (info.size > MAX_WORKSPACE_FILE_BYTES) {
      throw new WorkspaceFileError("file_too_large", "The file exceeds the 1 MiB editing limit");
    }
    const bytes = readFileSync(path);
    validateText(bytes);
    return {
      exists: true,
      bytes,
      revision: revision(bytes),
      modifiedAtMillis: Math.trunc(info.mtimeMs),
      mode: info.mode & 0o777,
    };
  }

  save(
    rootPath: string,
    relativePath: string,
    bytes: Uint8Array,
    expectedRevision: string | null,
    force = false,
  ): StoredWorkspaceFile {
    if (bytes.byteLength > MAX_WORKSPACE_FILE_BYTES) {
      throw new WorkspaceFileError("file_too_large", "The file exceeds the 1 MiB editing limit");
    }
    validateText(bytes);

    const root = workspaceRoot(rootPath);
    const normalized = normalizeRelativePath(relativePath, false);
    const path = resolveWorkspacePath(root, normalized, true);
    const before = this.read(root, normalized);
    if (!force && expectedRevision !== before.revision) {
      throw new WorkspaceFileError("conflict", "The file changed on the Mac", before);
    }

    const parent = resolveWorkspacePath(root, normalized.split("/").slice(0, -1).join("/"), false);
    if (!statSync(parent).isDirectory()) {
      throw new WorkspaceFileError("invalid_relative_path", "The file parent is not a directory");
    }
    const temporary = join(parent, `.${normalized.split("/").at(-1)}.sheltie-${randomUUID()}.tmp`);
    let descriptor: number | null = null;
    try {
      const mode = before.mode ?? 0o644;
      descriptor = openSync(
        temporary,
        constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW,
        mode,
      );
      writeFileSync(descriptor, bytes);
      chmodSync(temporary, mode);
      fsyncSync(descriptor);
      closeSync(descriptor);
      descriptor = null;

      const latest = this.read(root, normalized);
      if (!force && latest.revision !== before.revision) {
        throw new WorkspaceFileError("conflict", "The file changed on the Mac", latest);
      }
      renameSync(temporary, path);
      syncDirectory(parent);
      return this.read(root, normalized);
    } catch (error) {
      if (error instanceof WorkspaceFileError) throw error;
      throw new WorkspaceFileError("io_error", "The file could not be saved");
    } finally {
      if (descriptor !== null) closeSync(descriptor);
      rmSync(temporary, { force: true });
    }
  }
}

function workspaceRoot(rootPath: string): string {
  if (!isAbsolute(rootPath)) {
    throw new WorkspaceFileError("invalid_workspace_path", "The workspace root must be absolute");
  }
  let root: string;
  try {
    root = realpathSync(rootPath);
  } catch {
    throw new WorkspaceFileError("invalid_workspace_path", "The workspace root is unavailable");
  }
  if (!statSync(root).isDirectory()) {
    throw new WorkspaceFileError("invalid_workspace_path", "The workspace root is not a directory");
  }
  return root;
}

function normalizeRelativePath(relativePath: string, allowEmpty: boolean): string {
  if (typeof relativePath !== "string" || relativePath.includes("\0") || isAbsolute(relativePath)) {
    throw new WorkspaceFileError("invalid_relative_path", "The file path must be relative to the workspace");
  }
  if (relativePath === "") {
    if (allowEmpty) return "";
    throw new WorkspaceFileError("invalid_relative_path", "A file path is required");
  }
  const components = relativePath.split("/");
  if (components.some((component) => !component || component === "." || component === "..")) {
    throw new WorkspaceFileError("invalid_relative_path", "The file path is invalid");
  }
  return components.join("/");
}

function resolveWorkspacePath(root: string, relativePath: string, allowMissingFinal: boolean): string {
  if (!relativePath) return root;
  const components = relativePath.split("/");
  let current = root;
  for (const [index, component] of components.entries()) {
    const next = join(current, component);
    const final = index === components.length - 1;
    if (!existsSync(next)) {
      if (allowMissingFinal && final) return next;
      throw new WorkspaceFileError("invalid_relative_path", "The selected path is unavailable");
    }
    const info = lstatSync(next);
    if (info.isSymbolicLink()) {
      throw new WorkspaceFileError("invalid_relative_path", "Symbolic links cannot be edited remotely");
    }
    current = next;
  }
  const resolved = realpathSync(current);
  if (resolved !== root && !resolved.startsWith(`${root}${sep}`)) {
    throw new WorkspaceFileError("invalid_relative_path", "The selected path escaped the workspace");
  }
  return resolved;
}

function validateText(bytes: Uint8Array): void {
  if (bytes.includes(0)) {
    throw new WorkspaceFileError("invalid_encoding", "The editor supports UTF-8 text files only");
  }
  try {
    new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new WorkspaceFileError("invalid_encoding", "The editor supports UTF-8 text files only");
  }
}

function revision(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}

function syncDirectory(path: string): void {
  let descriptor: number | null = null;
  try {
    descriptor = openSync(path, constants.O_RDONLY);
    fsyncSync(descriptor);
  } catch {
    // The file has already been atomically renamed; directory fsync is best-effort across platforms.
  } finally {
    if (descriptor !== null) closeSync(descriptor);
  }
}
