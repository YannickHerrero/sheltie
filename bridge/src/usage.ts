import { readFileSync } from "node:fs";
import type { UsageMeter } from "./types.ts";

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

function validateMeter(value: unknown, index: number): UsageMeter {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`meter ${index} must be an object`);
  const meter = value as Record<string, unknown>;
  const remainingFraction = number(meter.remainingFraction, "remainingFraction");
  if (remainingFraction < 0 || remainingFraction > 1) throw new Error(`meter ${index} remainingFraction must be between 0 and 1`);
  return {
    id: string(meter.id, "id"),
    provider: string(meter.provider, "provider"),
    label: string(meter.label, "label"),
    remainingFraction,
    resetAtMillis: meter.resetAtMillis === null || meter.resetAtMillis === undefined
      ? null
      : number(meter.resetAtMillis, "resetAtMillis"),
    observedAtMillis: number(meter.observedAtMillis, "observedAtMillis"),
  };
}

function string(value: unknown, name: string): string {
  if (typeof value !== "string" || !value.trim()) throw new Error(`${name} must be a non-empty string`);
  return value;
}

function number(value: unknown, name: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) throw new Error(`${name} must be a finite number`);
  return value;
}
