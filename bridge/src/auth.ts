import {
  createHash,
  createPublicKey,
  randomBytes,
  randomInt,
  timingSafeEqual,
  verify,
  type KeyObject,
} from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { BridgeConfig } from "./config.ts";
import type { InstanceInfo } from "./types.ts";

interface StoredDevice {
  id: string;
  name: string;
  publicKeyDERBase64: string;
  tokenHash: string;
  pairedAtMillis: number;
  revokedAtMillis: number | null;
}

interface DeviceFile {
  version: 1;
  devices: StoredDevice[];
}

interface PendingPairing {
  id: string;
  name: string;
  publicKeyDERBase64: string;
  publicKey: KeyObject;
  challenge: Buffer;
  codeHash: Buffer;
  expiresAtMillis: number;
  attempts: number;
}

interface SessionCredential {
  tokenHash: Buffer;
  deviceID: string;
  expiresAtMillis: number;
}

export interface PairStartResult {
  pairingID: string;
  challengeBase64: string;
  expiresAtMillis: number;
}

export interface PairCompleteResult {
  deviceID: string;
  accessToken: string;
  instance: InstanceInfo;
}

export interface SessionResult {
  sessionToken: string;
  deviceID: string;
  expiresAtMillis: number;
}

export class AuthenticationError extends Error {
  constructor(readonly code: "unauthorized" | "forbidden" | "expired" | "invalid_pairing", message: string) {
    super(message);
    this.name = "AuthenticationError";
  }
}

function sha256(value: string | Buffer): Buffer {
  return createHash("sha256").update(value).digest();
}

function constantEqual(left: Buffer, right: Buffer): boolean {
  return left.byteLength === right.byteLength && timingSafeEqual(left, right);
}

function bearerToken(request: Request): string | null {
  const value = request.headers.get("authorization");
  if (!value?.startsWith("Bearer ")) return null;
  const token = value.slice("Bearer ".length).trim();
  return token || null;
}

export function validateIngress(request: Request, config: BridgeConfig): void {
  const host = (request.headers.get("host") ?? "").split(":", 1)[0]?.toLowerCase() ?? "";
  if (config.expectedHost && host !== config.expectedHost) {
    throw new AuthenticationError("forbidden", "unexpected host");
  }
  if (config.developmentMode) return;

  const login = request.headers.get("tailscale-user-login")?.trim().toLowerCase();
  if (!login || !config.allowedTailscaleLogins.has(login)) {
    throw new AuthenticationError("forbidden", "Tailscale identity is not allowed");
  }
}

export class AuthStore {
  private readonly devicesPath: string;
  private readonly pending = new Map<string, PendingPairing>();
  private readonly sessions = new Map<string, SessionCredential>();
  private devices: StoredDevice[];

  constructor(
    private readonly config: BridgeConfig,
    private readonly instance: InstanceInfo,
    private readonly onPairingCode: (message: string) => void = console.info,
    private readonly now: () => number = Date.now,
  ) {
    mkdirSync(config.dataDirectory, { recursive: true, mode: 0o700 });
    chmodSync(config.dataDirectory, 0o700);
    this.devicesPath = join(config.dataDirectory, "devices.json");
    this.devices = this.loadDevices();
  }

  startPairing(deviceName: string, publicKeyDERBase64: string): PairStartResult {
    const normalizedName = deviceName.trim().slice(0, 80);
    if (!normalizedName) throw new AuthenticationError("invalid_pairing", "device name is required");

    let publicKey: KeyObject;
    try {
      publicKey = createPublicKey({ key: Buffer.from(publicKeyDERBase64, "base64"), format: "der", type: "spki" });
      if (publicKey.asymmetricKeyType !== "ec") throw new Error("not an EC key");
    } catch {
      throw new AuthenticationError("invalid_pairing", "device public key is invalid");
    }

    this.prune();
    const id = crypto.randomUUID();
    const challenge = randomBytes(32);
    const code = `${randomInt(0, 1_000_000)}`.padStart(6, "0");
    const expiresAtMillis = this.now() + 5 * 60_000;
    this.pending.set(id, {
      id,
      name: normalizedName,
      publicKeyDERBase64,
      publicKey,
      challenge,
      codeHash: sha256(code),
      expiresAtMillis,
      attempts: 0,
    });
    this.onPairingCode(`[pairing] ${normalizedName}: code ${code} (expires in 5 minutes)`);
    return { pairingID: id, challengeBase64: challenge.toString("base64"), expiresAtMillis };
  }

  completePairing(pairingID: string, code: string, signatureDERBase64: string): PairCompleteResult {
    this.prune();
    const pairing = this.pending.get(pairingID);
    if (!pairing) throw new AuthenticationError("invalid_pairing", "pairing request is missing or expired");
    pairing.attempts += 1;
    if (pairing.attempts > 5) {
      this.pending.delete(pairingID);
      throw new AuthenticationError("invalid_pairing", "too many pairing attempts");
    }
    if (!constantEqual(pairing.codeHash, sha256(code.trim()))) {
      throw new AuthenticationError("invalid_pairing", "pairing code is incorrect");
    }

    const signature = Buffer.from(signatureDERBase64, "base64");
    if (!verify("sha256", pairing.challenge, pairing.publicKey, signature)) {
      throw new AuthenticationError("invalid_pairing", "device signature is invalid");
    }

    const deviceID = crypto.randomUUID();
    const accessToken = randomBytes(32).toString("base64url");
    this.devices.push({
      id: deviceID,
      name: pairing.name,
      publicKeyDERBase64: pairing.publicKeyDERBase64,
      tokenHash: sha256(accessToken).toString("hex"),
      pairedAtMillis: this.now(),
      revokedAtMillis: null,
    });
    this.pending.delete(pairingID);
    this.saveDevices();
    return { deviceID, accessToken, instance: this.instance };
  }

  refreshSession(request: Request): SessionResult {
    if (this.config.developmentMode && bearerToken(request) === "development") {
      return this.issueSession("development");
    }
    const token = bearerToken(request);
    if (!token) throw new AuthenticationError("unauthorized", "device credential is required");
    const tokenHash = sha256(token);
    const device = this.devices.find(
      (candidate) => candidate.revokedAtMillis === null && constantEqual(Buffer.from(candidate.tokenHash, "hex"), tokenHash),
    );
    if (!device) throw new AuthenticationError("unauthorized", "device credential is invalid or revoked");
    return this.issueSession(device.id);
  }

  authenticateSession(request: Request): { deviceID: string; expiresAtMillis: number } {
    if (this.config.developmentMode && bearerToken(request) === "development") {
      return { deviceID: "development", expiresAtMillis: this.now() + 60 * 60_000 };
    }
    const token = bearerToken(request);
    if (!token) throw new AuthenticationError("unauthorized", "session credential is required");
    const credential = this.sessions.get(sha256(token).toString("hex"));
    if (!credential) throw new AuthenticationError("unauthorized", "session credential is invalid");
    if (credential.expiresAtMillis <= this.now()) {
      this.sessions.delete(credential.tokenHash.toString("hex"));
      throw new AuthenticationError("expired", "session credential expired");
    }
    if (this.config.developmentMode && credential.deviceID === "development") {
      return { deviceID: credential.deviceID, expiresAtMillis: credential.expiresAtMillis };
    }
    const device = this.devices.find((candidate) => candidate.id === credential.deviceID && candidate.revokedAtMillis === null);
    if (!device) throw new AuthenticationError("unauthorized", "paired device is revoked");
    return { deviceID: credential.deviceID, expiresAtMillis: credential.expiresAtMillis };
  }

  revoke(deviceID: string): boolean {
    const device = this.devices.find((candidate) => candidate.id === deviceID && candidate.revokedAtMillis === null);
    if (!device) return false;
    device.revokedAtMillis = this.now();
    for (const [key, session] of this.sessions) {
      if (session.deviceID === deviceID) this.sessions.delete(key);
    }
    this.saveDevices();
    return true;
  }

  private issueSession(deviceID: string): SessionResult {
    this.prune();
    const sessionToken = randomBytes(32).toString("base64url");
    const expiresAtMillis = this.now() + 15 * 60_000;
    const tokenHash = sha256(sessionToken);
    this.sessions.set(tokenHash.toString("hex"), { tokenHash, deviceID, expiresAtMillis });
    return { sessionToken, deviceID, expiresAtMillis };
  }

  private prune() {
    const now = this.now();
    for (const [id, pairing] of this.pending) {
      if (pairing.expiresAtMillis <= now) this.pending.delete(id);
    }
    for (const [token, session] of this.sessions) {
      if (session.expiresAtMillis <= now) this.sessions.delete(token);
    }
  }

  private loadDevices(): StoredDevice[] {
    if (!existsSync(this.devicesPath)) return [];
    try {
      const parsed = JSON.parse(readFileSync(this.devicesPath, "utf8")) as DeviceFile;
      return parsed.version === 1 && Array.isArray(parsed.devices) ? parsed.devices : [];
    } catch (error) {
      throw new Error(`failed to read ${this.devicesPath}: ${String(error)}`);
    }
  }

  private saveDevices() {
    const temporary = `${this.devicesPath}.tmp`;
    writeFileSync(temporary, `${JSON.stringify({ version: 1, devices: this.devices } satisfies DeviceFile, null, 2)}\n`, {
      mode: 0o600,
    });
    chmodSync(temporary, 0o600);
    renameSync(temporary, this.devicesPath);
  }
}
