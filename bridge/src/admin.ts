import { chmodSync, existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export interface AdminDevice {
  id: string;
  name: string;
  publicKeyDERBase64: string;
  tokenHash: string;
  pairedAtMillis: number;
  revokedAtMillis: number | null;
}

interface DeviceFile {
  version: 1;
  devices: AdminDevice[];
}

export function loadDeviceFile(path: string): DeviceFile {
  if (!existsSync(path)) return { version: 1, devices: [] };
  const parsed = JSON.parse(readFileSync(path, "utf8")) as DeviceFile;
  if (parsed.version !== 1 || !Array.isArray(parsed.devices)) throw new Error("unsupported devices file");
  return parsed;
}

export function revokeDevice(path: string, deviceID: string, now = Date.now()): boolean {
  const file = loadDeviceFile(path);
  const device = file.devices.find((candidate) => candidate.id === deviceID && candidate.revokedAtMillis === null);
  if (!device) return false;
  device.revokedAtMillis = now;
  const temporary = `${path}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(file, null, 2)}\n`, { mode: 0o600 });
  chmodSync(temporary, 0o600);
  renameSync(temporary, path);
  return true;
}

if (import.meta.main) {
  const path = join(process.env.SHELTIE_DATA_DIR ?? join(homedir(), ".config", "sheltie"), "devices.json");
  const [command, deviceID] = process.argv.slice(2);
  if (command === "devices" || command === "list") {
    const devices = loadDeviceFile(path).devices.map(({ id, name, pairedAtMillis, revokedAtMillis }) => ({
      id,
      name,
      paired: new Date(pairedAtMillis).toISOString(),
      revoked: revokedAtMillis ? new Date(revokedAtMillis).toISOString() : null,
    }));
    console.table(devices);
  } else if (command === "revoke" && deviceID) {
    if (!revokeDevice(path, deviceID)) {
      console.error(`No active device found for ${deviceID}`);
      process.exit(1);
    }
    console.info(`Revoked ${deviceID}. Existing sessions are rejected on the next bridge restart; restart now for immediate eviction.`);
  } else {
    console.error("Usage: bun run admin devices | bun run admin revoke <device-id>");
    process.exit(2);
  }
}
