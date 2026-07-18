import type { BridgeConfig } from "./config.ts";
import type { HerdrClient } from "./herdr-client.ts";
import type { StreamServerMessage, TerminalSubscription } from "./types.ts";
import { compareVersions } from "./adapter.ts";

interface HerdrTerminalFrame {
  type: "terminal.frame";
  seq: number;
  encoding: "ansi";
  width: number;
  height: number;
  full: boolean;
  bytes: string;
}

interface HerdrTerminalClosed {
  type: "terminal.closed";
  reason?: string;
}

export class TerminalFeed {
  private process: ReturnType<typeof Bun.spawn> | null = null;
  private pollTimer: Timer | null = null;
  private stopped = false;
  private lastText: string | null = null;
  private sequence = 0;

  constructor(
    private readonly config: BridgeConfig,
    readonly subscription: TerminalSubscription,
    private readonly herdrVersion: string,
    private readonly client: HerdrClient,
    private readonly send: (message: StreamServerMessage) => void,
  ) {}

  start() {
    if (compareVersions(this.herdrVersion, "0.7.2") >= 0) {
      this.startObserver();
    } else {
      this.startPolling();
    }
  }

  stop() {
    this.stopped = true;
    if (this.pollTimer) clearInterval(this.pollTimer);
    this.pollTimer = null;
    try {
      this.process?.kill();
    } catch {
      // Process may have exited between the check and kill.
    }
    this.process = null;
  }

  private startObserver() {
    const sessionArguments = this.subscription.sessionID === "default" ? [] : ["--session", this.subscription.sessionID];
    const process = Bun.spawn(
      [
        this.config.herdrBinary,
        ...sessionArguments,
        "terminal",
        "session",
        "observe",
        this.subscription.paneID,
        "--cols",
        `${this.subscription.columns}`,
        "--rows",
        `${this.subscription.rows}`,
      ],
      { stdout: "pipe", stderr: "pipe", stdin: "ignore" },
    );
    this.process = process;
    void this.consumeObserver(process.stdout);
    void process.exited.then(async (exitCode) => {
      if (this.stopped || this.process !== process) return;
      this.process = null;
      if (exitCode !== 0) {
        const error = await new Response(process.stderr).text();
        console.warn(`[terminal] observer ${this.subscription.paneID} exited ${exitCode}: ${error.trim()}`);
      }
      this.startPolling();
    });
  }

  private async consumeObserver(stream: ReadableStream<Uint8Array>) {
    const reader = stream.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    while (!this.stopped) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      let newline = buffer.indexOf("\n");
      while (newline >= 0) {
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        if (line) this.consumeObserverLine(line);
        newline = buffer.indexOf("\n");
      }
    }
  }

  private consumeObserverLine(line: string) {
    let message: HerdrTerminalFrame | HerdrTerminalClosed;
    try {
      message = JSON.parse(line) as HerdrTerminalFrame | HerdrTerminalClosed;
    } catch {
      return;
    }
    if (message.type === "terminal.frame") {
      this.send({
        type: "terminal.frame",
        frame: {
          sessionID: this.subscription.sessionID,
          paneID: this.subscription.paneID,
          sequence: message.seq,
          full: message.full,
          columns: message.width,
          rows: message.height,
          bytesBase64: message.bytes,
        },
      });
    } else {
      this.send({
        type: "terminal.closed",
        terminal: {
          sessionID: this.subscription.sessionID,
          paneID: this.subscription.paneID,
          reason: message.reason ?? "Herdr closed the terminal stream",
        },
      });
    }
  }

  private startPolling() {
    if (this.stopped || this.pollTimer) return;
    const poll = () => void this.pollOnce();
    poll();
    this.pollTimer = setInterval(poll, this.config.terminalPollMilliseconds);
  }

  private async pollOnce() {
    if (this.stopped) return;
    try {
      const read = await this.client.readPane(this.subscription.paneID, Math.max(100, this.subscription.rows * 3));
      if (read.text === this.lastText) return;
      this.lastText = read.text;
      this.sequence += 1;
      const bytes = Buffer.from(`\u001b[2J\u001b[H${read.text}`, "utf8");
      this.send({
        type: "terminal.frame",
        frame: {
          sessionID: this.subscription.sessionID,
          paneID: this.subscription.paneID,
          sequence: this.sequence,
          full: true,
          columns: this.subscription.columns,
          rows: this.subscription.rows,
          bytesBase64: bytes.toString("base64"),
        },
      });
    } catch (error) {
      console.warn(`[terminal] ${this.subscription.paneID}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
}
