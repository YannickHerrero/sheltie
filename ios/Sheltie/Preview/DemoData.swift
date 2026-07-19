import Foundation
import SheltieProtocol

enum DemoData {
    static let snapshot: BootstrapSnapshot = {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let workspaces = [
            WorkspaceSnapshot(id: "w1", number: 1, label: "herdr", path: "~/Projects/herdr/website", branch: "master", activeTabID: "w1:t1", paneCount: 3, tabCount: 2, status: .working, focused: true),
            WorkspaceSnapshot(id: "w2", number: 2, label: "llm-proxy", path: "~/Projects/llm-proxy", branch: "master", activeTabID: "w2:t1", paneCount: 1, tabCount: 1, status: .blocked, focused: false),
            WorkspaceSnapshot(id: "w3", number: 3, label: "qmp", path: "autoresearch/qmp-panel", activeTabID: "w3:t1", paneCount: 1, tabCount: 1, status: .done, focused: false),
        ]
        let tabs = [
            TabSnapshot(id: "w1:t1", workspaceID: "w1", number: 1, label: "website", paneCount: 2, status: .working, focused: true),
            TabSnapshot(id: "w1:t2", workspaceID: "w1", number: 2, label: "docs preview", paneCount: 1, status: .done, focused: false),
            TabSnapshot(id: "w2:t1", workspaceID: "w2", number: 1, label: "proxy triage", paneCount: 1, status: .blocked, focused: false),
            TabSnapshot(id: "w3:t1", workspaceID: "w3", number: 1, label: "research", paneCount: 1, status: .done, focused: false),
        ]
        let panes = [
            PaneSnapshot(id: "w1:p1", terminalID: "term-claude", workspaceID: "w1", tabID: "w1:t1", title: "Implementation Agent", cwd: "~/Projects/herdr/website", kind: .agent, agentName: "claude", agentDisplayName: "Implementation Agent", agentStatus: .working, focused: true, revision: 42),
            PaneSnapshot(id: "w1:p2", terminalID: "term-bun", workspaceID: "w1", tabID: "w1:t1", title: "Astro Preview", cwd: "~/Projects/herdr", kind: .shell, agentStatus: .done, focused: false, revision: 17),
            PaneSnapshot(id: "w1:p3", terminalID: "term-dev", workspaceID: "w1", tabID: "w1:t2", title: "Docs Watcher", cwd: "~/Projects/herdr", kind: .shell, agentStatus: .done, focused: false, revision: 3),
            PaneSnapshot(id: "w2:p1", terminalID: "term-proxy", workspaceID: "w2", tabID: "w2:t1", title: "Proxy Agent", cwd: "~/Projects/llm-proxy", kind: .agent, agentName: "claude", agentDisplayName: "Proxy Agent", agentStatus: .blocked, focused: false, revision: 8),
            PaneSnapshot(id: "w3:p1", terminalID: "term-qmp", workspaceID: "w3", tabID: "w3:t1", title: "Research Agent", cwd: "~/Projects/qmp", kind: .agent, agentName: "codex", agentDisplayName: "Research Agent", agentStatus: .done, focused: false, revision: 9),
        ]
        let agents = [
            AgentSnapshot(id: "w1:p1", paneID: "w1:p1", workspaceID: "w1", tabID: "w1:t1", name: "claude", displayName: "herdr", status: .working, statusLabel: "working · claude"),
            AgentSnapshot(id: "explore", paneID: "w1:p3", workspaceID: "w1", tabID: "w1:t2", name: "opencode", displayName: "explore", status: .done, statusLabel: "done · opencode"),
            AgentSnapshot(id: "w2:p1", paneID: "w2:p1", workspaceID: "w2", tabID: "w2:t1", name: "claude", displayName: "llm-proxy", status: .blocked, statusLabel: "blocked · claude"),
            AgentSnapshot(id: "w3:p1", paneID: "w3:p1", workspaceID: "w3", tabID: "w3:t1", name: "codex", displayName: "qmp", status: .done, statusLabel: "done · codex"),
        ]
        let layouts = [
            PaneLayoutSnapshot(workspaceID: "w1", tabID: "w1:t1", zoomed: false, focusedPaneID: "w1:p1", root: .split(direction: .horizontal, ratio: 0.54, first: .pane(paneID: "w1:p1"), second: .pane(paneID: "w1:p2"))),
            PaneLayoutSnapshot(workspaceID: "w1", tabID: "w1:t2", zoomed: false, focusedPaneID: "w1:p3", root: .pane(paneID: "w1:p3")),
            PaneLayoutSnapshot(workspaceID: "w2", tabID: "w2:t1", zoomed: false, focusedPaneID: "w2:p1", root: .pane(paneID: "w2:p1")),
            PaneLayoutSnapshot(workspaceID: "w3", tabID: "w3:t1", zoomed: false, focusedPaneID: "w3:p1", root: .pane(paneID: "w3:p1")),
        ]
        return BootstrapSnapshot(
            bridge: BridgeInfo(version: "0.1.0", protocolVersion: 1, capabilities: ["pairing", "snapshots", "actions", "terminal.stream", "terminal.history", "usage.codex"]),
            instance: InstanceInfo(id: "studio", name: "Mac Studio", host: "studio.example.ts.net"),
            herdr: HerdrInfo(version: "0.7.3", protocolVersion: 17, capabilities: ["session.snapshot", "terminal.session.observe"]),
            sessions: [SessionSummary(id: "default", name: "default", isDefault: true, reachable: true)],
            activeSessionID: "default",
            workspaces: workspaces,
            tabs: tabs,
            panes: panes,
            agents: agents,
            layouts: layouts,
            focus: FocusSnapshot(workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1"),
            usageMeters: [UsageMeter(id: "codex-weekly", provider: "openai", label: "Codex · OpenAI weekly", remainingFraction: 0.68, resetAtMillis: now + 4 * 86_400_000, observedAtMillis: now)],
            generatedAtMillis: now
        )
    }()

    static let terminalFrames: [String: TerminalFrame] = [
        "w1:p1": frame(
            paneID: "w1:p1",
            sequence: 1,
            text: """
            \u{001B}[1;34mClaude Code\u{001B}[0m  \u{001B}[2m2.1.198 · Fable 5 with high effort\u{001B}[0m
            \u{001B}[2m~/Projects/herdr/website\u{001B}[0m

            ❯ make Sheltie feel native everywhere

            Read Herdr over the local socket. Keeping the spaces + agents
            split, then adapting terminal controls for touch.

            \u{001B}[33m● Plan\u{001B}[0m
              · preserve sessions when the app backgrounds
              · keep agent state visible beside every workspace
              · add a touch-first key row without shrinking the PTY

            ❯ perfect. keep the terminal itself real

            \u{001B}[33m⠇ Baking… (14m 11s · esc to interrupt)\u{001B}[0m
            """
        ),
        "w1:p2": frame(
            paneID: "w1:p2",
            sequence: 1,
            text: """
            \u{001B}[1m~/Projects/herdr\u{001B}[0m master
            ❯ bun run dev
            \u{001B}[2m$ node scripts/prepare-docs.mjs && astro dev\u{001B}[0m
            02:10:44 [types] Generated 0ms
            02:10:44 [content] Synced content

            \u{001B}[32mastro v5.18.1 ready in 668 ms\u{001B}[0m
            │ Local   http://localhost:4321/
              Network use --host to expose
            02:10:44 \u{001B}[32mwatching for file changes…\u{001B}[0m
            """
        ),
    ]

    static func terminalHistory(paneID: String, requestID: String) -> TerminalHistory {
        let olderLines = (1 ... 180).map { line in
            String(format: "\u{001B}[2m%03d\u{001B}[0m  Earlier terminal output retained by Herdr", line)
        }
        let liveTail = terminalFrames[paneID]?.bytes
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "Latest terminal output"
        let text = (olderLines.joined(separator: "\r\n") + "\r\n" + liveTail)
        return TerminalHistory(
            requestID: requestID,
            sessionID: "default",
            paneID: paneID,
            requestedLines: 1_000,
            bytesBase64: Data(text.utf8).base64EncodedString()
        )
    }

    private static func frame(paneID: String, sequence: Int64, text: String) -> TerminalFrame {
        TerminalFrame(
            sessionID: "default",
            paneID: paneID,
            sequence: sequence,
            full: true,
            columns: 100,
            rows: 36,
            bytesBase64: Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8).base64EncodedString()
        )
    }
}
