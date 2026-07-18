import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { BridgeConfig } from "../src/config.ts";
import type { HerdrClient } from "../src/herdr-client.ts";
import { TerminalFeed } from "../src/terminal-feed.ts";
import type { StreamServerMessage } from "../src/types.ts";

let directory: string | null = null;
const feeds: TerminalFeed[] = [];
afterEach(() => {
  for (const feed of feeds) feed.stop();
  feeds.length = 0;
  if (directory) rmSync(directory, { recursive: true, force: true });
  directory = null;
});

function config(binary: string, terminalPollMilliseconds = 10): BridgeConfig {
  directory ??= mkdtempSync(join(tmpdir(), "sheltie-terminal-"));
  return {
    bindHost: "127.0.0.1",
    port: 9847,
    configRoot: directory,
    primarySocketPath: join(directory, "herdr.sock"),
    dataDirectory: directory,
    instanceID: "studio",
    instanceName: "Mac Studio",
    publicHost: "studio.example.ts.net",
    expectedHost: null,
    allowedTailscaleLogins: new Set(),
    developmentMode: true,
    herdrBinary: binary,
    snapshotPollMilliseconds: 2_000,
    terminalPollMilliseconds,
  };
}

const subscription = { sessionID: "default", paneID: "w1:p1", columns: 100, rows: 30, writable: false };

function nextFrame(start: (send: (message: StreamServerMessage) => void) => void): Promise<StreamServerMessage> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("terminal frame timeout")), 2_000);
    start((message) => {
      if (message.type !== "terminal.frame") return;
      clearTimeout(timeout);
      resolve(message);
    });
  });
}

describe("terminal feed", () => {
  test("uses Herdr's observer envelope on 0.7.2 and newer", async () => {
    directory = mkdtempSync(join(tmpdir(), "sheltie-terminal-"));
    const binary = join(directory, "fake-herdr");
    const bytes = Buffer.from("\u001b[32mready\u001b[0m").toString("base64");
    writeFileSync(binary, `#!/bin/sh\nprintf '%s\\n' '${JSON.stringify({ type: "terminal.frame", seq: 9, encoding: "ansi", width: 100, height: 30, full: true, bytes })}'\nsleep 1\n`);
    chmodSync(binary, 0o700);

    const message = await nextFrame((send) => {
      const feed = new TerminalFeed(config(binary), subscription, "0.7.3", {} as HerdrClient, send);
      feeds.push(feed);
      feed.start();
    });
    expect(message).toMatchObject({
      type: "terminal.frame",
      frame: { paneID: "w1:p1", sequence: 9, full: true, columns: 100, rows: 30, bytesBase64: bytes },
    });
  });

  test("falls back to full pane.read frames on older Herdr versions", async () => {
    const client = {
      readPane: async () => ({ text: "ready", revision: 0, truncated: false }),
    } as unknown as HerdrClient;
    const message = await nextFrame((send) => {
      const feed = new TerminalFeed(config("herdr"), subscription, "0.7.1", client, send);
      feeds.push(feed);
      feed.start();
    });
    expect(message.type).toBe("terminal.frame");
    if (message.type === "terminal.frame") {
      expect(Buffer.from(message.frame.bytesBase64, "base64").toString("utf8")).toBe("\u001b[2J\u001b[Hready");
    }
  });
});
