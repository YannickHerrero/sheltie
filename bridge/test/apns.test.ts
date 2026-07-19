import { expect, test } from "bun:test";
import { generateKeyPairSync, verify } from "node:crypto";
import { apnsPayload, createAPNSJWT } from "../src/apns.ts";

test("creates a valid ES256 APNs provider token", () => {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const token = createAPNSJWT("KEY123", "TEAM123", 1_700_000_000, privateKey);
  const [header, claims, signature] = token.split(".");

  expect(JSON.parse(Buffer.from(header!, "base64url").toString("utf8"))).toEqual({ alg: "ES256", kid: "KEY123" });
  expect(JSON.parse(Buffer.from(claims!, "base64url").toString("utf8"))).toEqual({ iss: "TEAM123", iat: 1_700_000_000 });
  expect(verify(
    "sha256",
    Buffer.from(`${header}.${claims}`),
    { key: publicKey, dsaEncoding: "ieee-p1363" },
    Buffer.from(signature!, "base64url"),
  )).toBeTrue();
});

test("keeps APNs alert payloads generic and private", () => {
  const done = JSON.stringify(apnsPayload("done"));
  const blocked = JSON.stringify(apnsPayload("blocked"));
  expect(done).toContain("finished");
  expect(blocked).toContain("attention");
  expect(done).not.toContain("workspace");
  expect(blocked).not.toContain("pane");
});
