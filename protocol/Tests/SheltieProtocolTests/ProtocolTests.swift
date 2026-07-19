import Foundation
import Testing
@testable import SheltieProtocol

@Test func decodesBootstrapFixtureAndRecursiveLayout() throws {
    let url = try #require(Bundle.module.url(forResource: "bootstrap-v1", withExtension: "json", subdirectory: "Fixtures"))
    let snapshot = try JSONDecoder().decode(BootstrapSnapshot.self, from: Data(contentsOf: url))

    #expect(snapshot.protocolVersion == SheltieProtocolVersion.current)
    #expect(snapshot.instance.name == "Mac Studio")
    #expect(snapshot.workspaces.count == 2)
    #expect(snapshot.panes.first?.kind == .agent)
    #expect(snapshot.usageMeters.first?.remainingFraction == 0.68)

    guard case let .split(direction, ratio, first, second) = snapshot.layouts[0].root else {
        Issue.record("Expected a split root")
        return
    }
    #expect(direction == .horizontal)
    #expect(ratio == 0.54)
    #expect(first == .pane(paneID: "w1:p1"))
    #expect(second == .pane(paneID: "w1:p2"))
}

@Test func bootstrapFixtureRoundTripsWithoutLoss() throws {
    let url = try #require(Bundle.module.url(forResource: "bootstrap-v1", withExtension: "json", subdirectory: "Fixtures"))
    let decoder = JSONDecoder()
    let original = try decoder.decode(BootstrapSnapshot.self, from: Data(contentsOf: url))
    let encoded = try JSONEncoder().encode(original)
    let decoded = try decoder.decode(BootstrapSnapshot.self, from: encoded)

    #expect(decoded == original)
}

@Test func streamMessagesRoundTrip() throws {
    let frame = TerminalFrame(
        sessionID: "default",
        paneID: "w1:p1",
        sequence: 7,
        full: true,
        columns: 120,
        rows: 40,
        bytesBase64: Data("hello".utf8).base64EncodedString()
    )
    let history = TerminalHistory(
        requestID: "history-1",
        sessionID: "default",
        paneID: "w1:p1",
        requestedLines: 1_000,
        bytesBase64: Data("older output".utf8).base64EncodedString()
    )
    let todo = WorkspaceTodoDocument(
        requestID: "todo-1",
        sessionID: "default",
        workspaceID: "w1",
        exists: true,
        content: "- [ ] Test\n",
        revision: "abc"
    )
    let messages: [StreamServerMessage] = [
        .terminalFrame(frame),
        .terminalHistory(history),
        .workspaceTodo(todo),
        .terminalClosed(.init(sessionID: "default", paneID: "w1:p1", reason: "done")),
        .actionResult(.init(requestID: "request-1", ok: true)),
        .sessionExpiring(expiresAtMillis: 1_800_000_000_000),
        .ping(id: "ping-1"),
    ]

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    for message in messages {
        let decoded = try decoder.decode(StreamServerMessage.self, from: encoder.encode(message))
        #expect(decoded == message)
    }
    #expect(frame.bytes == Data("hello".utf8))
    #expect(history.bytes == Data("older output".utf8))
}

@Test func clientActionsAndSubscriptionsRoundTrip() throws {
    let action = ActionCommand(
        requestID: "request-2",
        sessionID: "default",
        type: .agentMessage,
        targetID: "w1:p1",
        text: "Ship it"
    )
    let move = ActionCommand(
        requestID: "request-3",
        sessionID: "default",
        type: .movePane,
        targetID: "w1:p1",
        moveDestination: .newTab(workspaceID: "w1", label: "moved")
    )
    let messages: [StreamClientMessage] = [
        .subscribe([.init(sessionID: "default", paneID: "w1:p1", columns: 100, rows: 32, writable: true)]),
        .terminalHistoryRequest(.init(requestID: "history-2", sessionID: "default", paneID: "w1:p1", lines: 1_000)),
        .workspaceTodoRead(.init(requestID: "todo-read", sessionID: "default", workspaceID: "w1")),
        .workspaceTodoSave(.init(
            requestID: "todo-save",
            sessionID: "default",
            workspaceID: "w1",
            content: "- [ ] Ship\n",
            expectedRevision: "abc"
        )),
        .action(action),
        .action(move),
        .resync,
        .pong(id: "ping-2"),
    ]

    for message in messages {
        let data = try JSONEncoder().encode(message)
        #expect(try JSONDecoder().decode(StreamClientMessage.self, from: data) == message)
    }
}
