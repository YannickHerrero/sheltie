import { appendFileSync, chmodSync, closeSync, mkdirSync, openSync } from "node:fs";
import { join } from "node:path";
import type { ActionCommand, ActionResult } from "./types.ts";

export class AuditLog {
  private readonly path: string;

  constructor(dataDirectory: string) {
    mkdirSync(dataDirectory, { recursive: true, mode: 0o700 });
    this.path = join(dataDirectory, "audit.jsonl");
    const descriptor = openSync(this.path, "a", 0o600);
    closeSync(descriptor);
    chmodSync(this.path, 0o600);
  }

  record(deviceID: string, action: ActionCommand, result: ActionResult) {
    const entry = {
      at: new Date().toISOString(),
      deviceID,
      requestID: action.requestID,
      sessionID: action.sessionID,
      type: action.type,
      targetID: action.targetID ?? null,
      ok: result.ok,
      errorCode: result.errorCode,
    };
    appendFileSync(this.path, `${JSON.stringify(entry)}\n`, { encoding: "utf8", mode: 0o600 });
  }
}
