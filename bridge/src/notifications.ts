import type { AuthStore } from "./auth.ts";
import type { PushSending } from "./apns.ts";
import type { BridgeStateProviding } from "./state-engine.ts";
import type { AgentStatus, BootstrapSnapshot } from "./types.ts";

export class AgentNotificationService {
  private readonly statuses = new Map<string, AgentStatus>();
  private readonly seededSessions = new Set<string>();
  private removeListener: (() => void) | null = null;

  constructor(
    private readonly state: BridgeStateProviding,
    private readonly auth: AuthStore,
    private readonly sender: PushSending | null,
  ) {}

  start(): void {
    if (this.removeListener) return;
    this.removeListener = this.state.addSnapshotListener((snapshot) => this.consume(snapshot));
  }

  stop(): void {
    this.removeListener?.();
    this.removeListener = null;
  }

  consume(snapshot: BootstrapSnapshot): void {
    const sessionID = snapshot.activeSessionID ?? "default";
    const currentKeys = new Set<string>();
    const seeded = this.seededSessions.has(sessionID);
    for (const agent of snapshot.agents) {
      const key = `${sessionID}:${agent.paneID}`;
      currentKeys.add(key);
      const previous = this.statuses.get(key);
      this.statuses.set(key, agent.status);
      if (seeded && previous !== undefined && previous !== agent.status && (agent.status === "done" || agent.status === "blocked")) {
        void this.deliver(agent.status);
      }
    }
    for (const key of this.statuses.keys()) {
      if (key.startsWith(`${sessionID}:`) && !currentKeys.has(key)) this.statuses.delete(key);
    }
    this.seededSessions.add(sessionID);
  }

  private async deliver(status: "done" | "blocked"): Promise<void> {
    if (!this.sender) return;
    const targets = this.auth.notificationTargets(status);
    await Promise.all(targets.map(async (target) => {
      try {
        const result = await this.sender!.send(target.deviceToken, status);
        if (result.invalidToken) this.auth.clearNotificationToken(target.deviceID);
      } catch (error) {
        console.warn(`[notifications] APNs delivery failed: ${error instanceof Error ? error.message : "request failed"}`);
      }
    }));
  }
}
