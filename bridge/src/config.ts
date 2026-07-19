import { homedir, hostname } from "node:os";
import { join } from "node:path";

export interface APNSConfig {
  keyPath: string;
  keyID: string;
  teamID: string;
  topic: string;
  environment: "development" | "production";
}

export interface BridgeConfig {
  bindHost: string;
  port: number;
  configRoot: string;
  primarySocketPath: string;
  dataDirectory: string;
  instanceID: string;
  instanceName: string;
  publicHost: string;
  expectedHost: string | null;
  allowedTailscaleLogins: Set<string>;
  developmentMode: boolean;
  herdrBinary: string;
  snapshotPollMilliseconds: number;
  terminalPollMilliseconds: number;
  usageRefreshMilliseconds: number;
  codexBinary: string;
  apns: APNSConfig | null;
  usageFile?: string;
}

function positiveInteger(name: string, fallback: number): number {
  const raw = process.env[name];
  if (!raw) return fallback;
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }
  return parsed;
}

function splitSet(raw: string | undefined): Set<string> {
  return new Set(
    (raw ?? "")
      .split(",")
      .map((value) => value.trim().toLowerCase())
      .filter(Boolean),
  );
}

function loadAPNSConfig(): APNSConfig | null {
  const values = {
    keyPath: process.env.SHELTIE_APNS_KEY_PATH,
    keyID: process.env.SHELTIE_APNS_KEY_ID,
    teamID: process.env.SHELTIE_APNS_TEAM_ID,
    topic: process.env.SHELTIE_APNS_TOPIC,
  };
  const configured = Object.values(values).filter(Boolean).length;
  if (configured === 0) return null;
  if (configured !== Object.keys(values).length) throw new Error("all SHELTIE_APNS_* credentials are required");
  const environment = process.env.SHELTIE_APNS_ENVIRONMENT ?? "production";
  if (environment !== "development" && environment !== "production") {
    throw new Error("SHELTIE_APNS_ENVIRONMENT must be development or production");
  }
  return {
    keyPath: values.keyPath!,
    keyID: values.keyID!,
    teamID: values.teamID!,
    topic: values.topic!,
    environment,
  };
}

export function loadConfig(): BridgeConfig {
  const configRoot = process.env.HERDR_CONFIG_ROOT ?? join(homedir(), ".config", "herdr");
  const machineName = hostname();
  const publicHost = process.env.SHELTIE_PUBLIC_HOST ?? `${machineName}.ts.net`;
  const developmentMode = process.env.SHELTIE_DEV_MODE === "1";

  const config: BridgeConfig = {
    bindHost: process.env.SHELTIE_BIND_HOST ?? "127.0.0.1",
    port: positiveInteger("SHELTIE_PORT", 9847),
    configRoot,
    primarySocketPath: process.env.HERDR_SOCKET_PATH ?? join(configRoot, "herdr.sock"),
    dataDirectory: process.env.SHELTIE_DATA_DIR ?? join(homedir(), ".config", "sheltie"),
    instanceID: process.env.SHELTIE_INSTANCE_ID ?? machineName.toLowerCase().replace(/[^a-z0-9-]/g, "-"),
    instanceName: process.env.SHELTIE_INSTANCE_NAME ?? machineName,
    publicHost,
    expectedHost: process.env.SHELTIE_EXPECTED_HOST?.toLowerCase() ?? (developmentMode ? null : publicHost.toLowerCase()),
    allowedTailscaleLogins: splitSet(process.env.SHELTIE_ALLOWED_TAILSCALE_LOGINS),
    developmentMode,
    herdrBinary: process.env.HERDR_BINARY ?? "herdr",
    snapshotPollMilliseconds: positiveInteger("SHELTIE_SNAPSHOT_POLL_MS", 2_000),
    terminalPollMilliseconds: positiveInteger("SHELTIE_TERMINAL_POLL_MS", 350),
    usageRefreshMilliseconds: positiveInteger("SHELTIE_USAGE_REFRESH_MS", 60_000),
    codexBinary: process.env.SHELTIE_CODEX_BINARY ?? "codex",
    apns: loadAPNSConfig(),
    ...(process.env.SHELTIE_USAGE_FILE ? { usageFile: process.env.SHELTIE_USAGE_FILE } : {}),
  };

  if (config.bindHost !== "127.0.0.1" && config.bindHost !== "::1") {
    throw new Error("SHELTIE_BIND_HOST must be loopback; expose the bridge through Tailscale Serve");
  }
  if (!developmentMode && config.allowedTailscaleLogins.size === 0) {
    throw new Error("SHELTIE_ALLOWED_TAILSCALE_LOGINS is required outside development mode");
  }
  return config;
}
