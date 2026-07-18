import { existsSync, readdirSync } from "node:fs";
import { join } from "node:path";

export interface HerdrSessionLocation {
  id: string;
  name: string;
  socketPath: string;
  isDefault: boolean;
}

export function discoverSessions(configRoot: string, primarySocketPath: string): HerdrSessionLocation[] {
  const sessions: HerdrSessionLocation[] = [];
  if (existsSync(primarySocketPath)) {
    sessions.push({ id: "default", name: "default", socketPath: primarySocketPath, isDefault: true });
  }

  const sessionsDirectory = join(configRoot, "sessions");
  if (!existsSync(sessionsDirectory)) return sessions;

  for (const entry of readdirSync(sessionsDirectory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    if (!entry.isDirectory()) continue;
    const socketPath = join(sessionsDirectory, entry.name, "herdr.sock");
    if (!existsSync(socketPath)) continue;
    sessions.push({ id: entry.name, name: entry.name, socketPath, isDefault: false });
  }
  return sessions;
}
