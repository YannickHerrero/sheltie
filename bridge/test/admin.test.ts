import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadDeviceFile, revokeDevice } from "../src/admin.ts";

let directory: string | null = null;
afterEach(() => {
  if (directory) rmSync(directory, { recursive: true, force: true });
  directory = null;
});

test("revokes a paired device without exposing or changing credentials", () => {
  directory = mkdtempSync(join(tmpdir(), "sheltie-admin-"));
  const path = join(directory, "devices.json");
  writeFileSync(path, JSON.stringify({
    version: 1,
    devices: [{
      id: "device-1",
      name: "iPad",
      publicKeyDERBase64: "public",
      tokenHash: "secret-hash",
      pairedAtMillis: 1,
      revokedAtMillis: null,
    }],
  }));

  expect(revokeDevice(path, "device-1", 42)).toBeTrue();
  const device = loadDeviceFile(path).devices[0];
  expect(device?.revokedAtMillis).toBe(42);
  expect(device?.tokenHash).toBe("secret-hash");
  expect(revokeDevice(path, "device-1", 43)).toBeFalse();
  expect(readFileSync(path, "utf8")).toContain('"revokedAtMillis": 42');
});
