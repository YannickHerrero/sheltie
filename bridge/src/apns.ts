import { createPrivateKey, sign, type KeyObject } from "node:crypto";
import { readFileSync } from "node:fs";
import { connect } from "node:http2";
import type { APNSConfig } from "./config.ts";

export interface PushResult {
  accepted: boolean;
  invalidToken: boolean;
}

export interface PushSending {
  send(deviceToken: string, status: "done" | "blocked"): Promise<PushResult>;
}

export class APNSProvider implements PushSending {
  private readonly key: KeyObject;
  private cachedJWT: { value: string; issuedAtSeconds: number } | null = null;

  constructor(
    private readonly config: APNSConfig,
    private readonly now: () => number = Date.now,
  ) {
    this.key = createPrivateKey(readFileSync(config.keyPath));
  }

  async send(deviceToken: string, status: "done" | "blocked"): Promise<PushResult> {
    const origin = this.config.environment === "production"
      ? "https://api.push.apple.com"
      : "https://api.sandbox.push.apple.com";
    const client = connect(origin);
    const jwt = this.jwt();
    const payload = JSON.stringify(apnsPayload(status));

    return await new Promise<PushResult>((resolve, reject) => {
      let settled = false;
      const finish = (result: PushResult | Error) => {
        if (settled) return;
        settled = true;
        client.close();
        result instanceof Error ? reject(result) : resolve(result);
      };
      const timer = setTimeout(() => finish(new Error("APNs request timed out")), 5_000);
      client.once("error", (error) => {
        clearTimeout(timer);
        finish(error);
      });
      const request = client.request({
        ":method": "POST",
        ":path": `/3/device/${deviceToken}`,
        authorization: `bearer ${jwt}`,
        "apns-topic": this.config.topic,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": "0",
        "content-type": "application/json",
      });
      let statusCode = 0;
      request.on("response", (headers) => {
        statusCode = Number(headers[":status"] ?? 0);
      });
      request.on("data", () => {
        // APNs error bodies are intentionally not logged because they can include token metadata.
      });
      request.on("error", (error) => {
        clearTimeout(timer);
        finish(error);
      });
      request.on("end", () => {
        clearTimeout(timer);
        finish({
          accepted: statusCode === 200,
          invalidToken: statusCode === 400 || statusCode === 410,
        });
      });
      request.end(payload);
    });
  }

  private jwt(): string {
    const issuedAtSeconds = Math.floor(this.now() / 1_000);
    if (this.cachedJWT && issuedAtSeconds - this.cachedJWT.issuedAtSeconds < 50 * 60) return this.cachedJWT.value;
    const value = createAPNSJWT(this.config.keyID, this.config.teamID, issuedAtSeconds, this.key);
    this.cachedJWT = { value, issuedAtSeconds };
    return value;
  }
}

export function apnsPayload(status: "done" | "blocked"): Record<string, unknown> {
  return {
    aps: {
      alert: {
        title: "Sheltie",
        body: status === "done" ? "An agent finished its work." : "An agent needs your attention.",
      },
      sound: "default",
    },
  };
}

export function createAPNSJWT(keyID: string, teamID: string, issuedAtSeconds: number, key: KeyObject): string {
  const header = base64URL(JSON.stringify({ alg: "ES256", kid: keyID }));
  const claims = base64URL(JSON.stringify({ iss: teamID, iat: issuedAtSeconds }));
  const input = `${header}.${claims}`;
  const signature = sign("sha256", Buffer.from(input), { key, dsaEncoding: "ieee-p1363" });
  return `${input}.${signature.toString("base64url")}`;
}

function base64URL(value: string): string {
  return Buffer.from(value, "utf8").toString("base64url");
}
