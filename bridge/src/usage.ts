import { readFileSync } from "node:fs";
import type { BridgeConfig } from "./config.ts";
import type { UsageMeter } from "./types.ts";

const CODEX_REQUEST_TIMEOUT_MS = 5_000;

export interface UsageLoading {
  load(): Promise<UsageMeter[]>;
}

export class UsageProvider implements UsageLoading {
  private cached: UsageMeter[] = [];
  private lastAttemptMillis = 0;
  private inFlight: Promise<UsageMeter[]> | null = null;

  constructor(
    private readonly config: BridgeConfig,
    private readonly now: () => number = Date.now,
  ) {}

  async load(): Promise<UsageMeter[]> {
    if (this.config.usageFile) return loadUsageMeters(this.config.usageFile);
    const now = this.now();
    if (now - this.lastAttemptMillis < this.config.usageRefreshMilliseconds) return this.cached;
    if (this.inFlight) return await this.inFlight;
    this.lastAttemptMillis = now;
    this.inFlight = collectCodexUsage(this.config.codexBinary, this.now)
      .then((meters) => {
        this.cached = meters;
        return meters;
      })
      .catch((error) => {
        console.warn(`[usage] Codex limits unavailable: ${error instanceof Error ? error.message : "collector failed"}`);
        return this.cached;
      })
      .finally(() => {
        this.inFlight = null;
      });
    return await this.inFlight;
  }
}

export function loadUsageMeters(path: string | undefined): UsageMeter[] {
  if (!path) return [];
  try {
    const value = JSON.parse(readFileSync(path, "utf8")) as unknown;
    if (!Array.isArray(value)) throw new Error("root must be an array");
    return value.map((entry, index) => validateMeter(entry, index));
  } catch (error) {
    console.warn(`[usage] ${path}: ${error instanceof Error ? error.message : String(error)}`);
    return [];
  }
}

export async function collectCodexUsage(
  binary: string,
  now: () => number = Date.now,
): Promise<UsageMeter[]> {
  const process = Bun.spawn([binary, "app-server", "--stdio"], {
    stdin: "pipe",
    stdout: "pipe",
    stderr: "ignore",
  });
  const requests = [
    { id: 1, method: "initialize", params: { clientInfo: { name: "sheltie-bridge", version: "0.1.0" } } },
    { method: "initialized" },
    { id: 2, method: "account/rateLimits/read", params: null },
  ];

  try {
    process.stdin.write(`${requests.map((request) => JSON.stringify(request)).join("\n")}\n`);
    process.stdin.flush();
    const response = await Promise.race([
      readJSONRPCResponse(process.stdout, 2),
      new Promise<never>((_, reject) => setTimeout(() => reject(new Error("collector timed out")), CODEX_REQUEST_TIMEOUT_MS)),
    ]);
    if (response.error) throw new Error("Codex rejected the rate-limit request");
    return codexRateLimitMeters(response.result, now());
  } finally {
    try {
      process.stdin.end();
      process.kill();
    } catch {
      // The short-lived collector may already have exited.
    }
  }
}

async function readJSONRPCResponse(
  stream: ReadableStream<Uint8Array>,
  requestID: number,
): Promise<{ result?: unknown; error?: unknown }> {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) throw new Error("collector closed before responding");
      buffer += decoder.decode(value, { stream: true });
      let newline = buffer.indexOf("\n");
      while (newline >= 0) {
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        if (line) {
          const message = JSON.parse(line) as { id?: unknown; result?: unknown; error?: unknown };
          if (message.id === requestID) return message;
        }
        newline = buffer.indexOf("\n");
      }
    }
  } finally {
    reader.releaseLock();
  }
}

function codexRateLimitMeters(result: unknown, observedAtMillis: number): UsageMeter[] {
  if (!result || typeof result !== "object" || Array.isArray(result)) throw new Error("Codex returned malformed limits");
  const record = result as Record<string, unknown>;
  const byID = record.rateLimitsByLimitId;
  const codex = byID && typeof byID === "object" && !Array.isArray(byID)
    ? (byID as Record<string, unknown>).codex
    : undefined;
  const snapshot = codex ?? record.rateLimits;
  if (!snapshot || typeof snapshot !== "object" || Array.isArray(snapshot)) return [];
  const limit = snapshot as Record<string, unknown>;
  const windows = [limit.primary, limit.secondary]
    .filter((value): value is Record<string, unknown> => Boolean(value) && typeof value === "object" && !Array.isArray(value));
  if (windows.length === 0) return [];
  const selected = windows.sort((left, right) => duration(right) - duration(left))[0]!;
  const usedPercent = finiteNumber(selected.usedPercent, "usedPercent");
  if (usedPercent < 0 || usedPercent > 100) throw new Error("Codex returned an invalid used percentage");
  const resetsAt = selected.resetsAt;
  const resetAtMillis = resetsAt === null || resetsAt === undefined
    ? null
    : finiteNumber(resetsAt, "resetsAt") * 1_000;
  const weekly = duration(selected) >= 6 * 24 * 60;
  return [{
    id: "codex-weekly",
    provider: "openai",
    label: weekly ? "Codex · Weekly" : "Codex limit",
    remainingFraction: (100 - usedPercent) / 100,
    resetAtMillis,
    observedAtMillis,
  }];
}

function duration(value: Record<string, unknown>): number {
  return typeof value.windowDurationMins === "number" && Number.isFinite(value.windowDurationMins)
    ? value.windowDurationMins
    : 0;
}

function validateMeter(value: unknown, index: number): UsageMeter {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`meter ${index} must be an object`);
  const meter = value as Record<string, unknown>;
  const remainingFraction = finiteNumber(meter.remainingFraction, "remainingFraction");
  if (remainingFraction < 0 || remainingFraction > 1) throw new Error(`meter ${index} remainingFraction must be between 0 and 1`);
  return {
    id: nonEmptyString(meter.id, "id"),
    provider: nonEmptyString(meter.provider, "provider"),
    label: nonEmptyString(meter.label, "label"),
    remainingFraction,
    resetAtMillis: meter.resetAtMillis === null || meter.resetAtMillis === undefined
      ? null
      : finiteNumber(meter.resetAtMillis, "resetAtMillis"),
    observedAtMillis: finiteNumber(meter.observedAtMillis, "observedAtMillis"),
  };
}

function nonEmptyString(value: unknown, name: string): string {
  if (typeof value !== "string" || !value.trim()) throw new Error(`${name} must be a non-empty string`);
  return value;
}

function finiteNumber(value: unknown, name: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) throw new Error(`${name} must be a finite number`);
  return value;
}
