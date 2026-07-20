import CryptoKit
import Foundation
import SheltieProtocol
import Testing
@testable import Sheltie

private final class MemoryInstanceRepository: InstancePersisting {
    var profiles: [InstanceProfile] = []
    var selectedID: String?
    var tokens: [String: String] = [:]

    func loadProfiles() -> [InstanceProfile] { profiles }
    func saveProfiles(_ profiles: [InstanceProfile]) { self.profiles = profiles }
    func loadSelectedID() -> String? { selectedID }
    func saveSelectedID(_ id: String?) { selectedID = id }
    func accessToken(for instanceID: String) throws -> String? { tokens[instanceID] }
    func setAccessToken(_ token: String, for instanceID: String) throws { tokens[instanceID] = token }
    func removeAccessToken(for instanceID: String) throws { tokens[instanceID] = nil }
}

private actor SuspendedBridgeClient: BridgeConnecting {
    private let snapshot: BootstrapSnapshot
    private let resumeWhenDisconnected: Bool
    private var receiveContinuation: CheckedContinuation<StreamServerMessage, any Error>?
    private(set) var disconnectCount = 0

    init(snapshot: BootstrapSnapshot, resumeWhenDisconnected: Bool) {
        self.snapshot = snapshot
        self.resumeWhenDisconnected = resumeWhenDisconnected
    }

    func refreshSession(accessToken: String) async throws -> SessionCredential {
        SessionCredential(sessionToken: "session", deviceID: "device", expiresAtMillis: .max)
    }

    func bootstrap(sessionID: String?, sessionToken: String) async throws -> BootstrapSnapshot { snapshot }
    func connectStream(sessionID: String, sessionToken: String) async throws {}

    func receiveStreamMessage() async throws -> StreamServerMessage {
        try await withCheckedThrowingContinuation { continuation in
            receiveContinuation = continuation
        }
    }

    func sendStreamMessage(_ message: StreamClientMessage) async throws {}

    func disconnect() async {
        disconnectCount += 1
        if resumeWhenDisconnected, let continuation = receiveContinuation {
            receiveContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
    }

    func isReceiving() -> Bool { receiveContinuation != nil }

    func failStaleReceive() {
        guard let continuation = receiveContinuation else { return }
        receiveContinuation = nil
        continuation.resume(throwing: URLError(.networkConnectionLost))
    }
}

private func snapshot(instanceID: String, name: String) -> BootstrapSnapshot {
    let source = DemoData.snapshot
    return BootstrapSnapshot(
        bridge: source.bridge,
        instance: InstanceInfo(id: instanceID, name: name, host: "\(instanceID).example.ts.net"),
        herdr: source.herdr,
        sessions: source.sessions,
        activeSessionID: source.activeSessionID,
        workspaces: source.workspaces,
        tabs: source.tabs,
        panes: source.panes,
        agents: source.agents,
        layouts: source.layouts,
        focus: source.focus,
        usageMeters: source.usageMeters,
        generatedAtMillis: source.generatedAtMillis
    )
}

@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0 ..< 100 {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

private func eventuallyReceiving(_ client: SuspendedBridgeClient) async -> Bool {
    for _ in 0 ..< 100 {
        if await client.isReceiving() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

@MainActor
@Test func demoStoreBootstrapsSelectionAndTerminalFrames() {
    let store = AppStore(repository: MemoryInstanceRepository(), arguments: ["tests", "--demo"])

    #expect(store.phase == .connected)
    #expect(store.selectedWorkspaceID == "w1")
    #expect(store.selectedTabID == "w1:t1")
    #expect(store.selectedPaneID == "w1:p1")
    #expect(store.terminalFrames["w1:p1"]?.full == true)

    store.requestTerminalHistory(for: "w1:p1")
    #expect(store.terminalHistories["w1:p1"]?.bytes != nil)
    #expect(store.terminalHistoryLoadingPaneIDs.contains("w1:p1") == false)

    let readID = store.requestWorkspaceTodo(for: "w1")
    #expect(store.workspaceTodos["w1"]?.requestID == readID)
    #expect(store.workspaceTodos["w1"]?.content?.contains("TestFlight") == true)
    let saveID = store.saveWorkspaceTodo(
        workspaceID: "w1",
        content: "- [ ] Test todo.md\n",
        expectedRevision: store.workspaceTodos["w1"]?.revision
    )
    #expect(store.workspaceTodos["w1"]?.requestID == saveID)
    #expect(store.workspaceTodos["w1"]?.content == "- [ ] Test todo.md\n")

    store.requestWorkspaceDirectory(workspaceID: "w1", relativePath: "")
    #expect(store.workspaceDirectory(workspaceID: "w1", relativePath: "")?.entries.first?.name == "Sources")
    store.requestWorkspaceFile(workspaceID: "w1", relativePath: "Sources/App.swift")
    let file = try! #require(store.workspaceFile(workspaceID: "w1", relativePath: "Sources/App.swift"))
    #expect(file.bytes.flatMap { String(data: $0, encoding: .utf8) }?.contains("DemoApp") == true)
    let fileSaveID = store.saveWorkspaceFile(file, content: "let savedFromIPad = true\n")
    #expect(store.workspaceFile(workspaceID: "w1", relativePath: "Sources/App.swift")?.requestID == fileSaveID)
    #expect(store.workspaceFile(workspaceID: "w1", relativePath: "Sources/App.swift")?.bytes == Data("let savedFromIPad = true\n".utf8))
}

@MainActor
@Test func switchingHostsIgnoresTheCancelledConnection() async {
    let repository = MemoryInstanceRepository()
    let firstURL = URL(string: "https://first.example.ts.net/sheltie")!
    let secondURL = URL(string: "https://second.example.ts.net/sheltie")!
    repository.profiles = [
        InstanceProfile(id: "local-first", displayName: "First", baseURL: firstURL, deviceID: "device-first"),
        InstanceProfile(id: "local-second", displayName: "Second", baseURL: secondURL, deviceID: "device-second"),
    ]
    repository.selectedID = "local-first"
    repository.tokens = ["local-first": "first-token", "local-second": "second-token"]
    let first = SuspendedBridgeClient(snapshot: snapshot(instanceID: "remote-first", name: "First"), resumeWhenDisconnected: false)
    let second = SuspendedBridgeClient(snapshot: snapshot(instanceID: "remote-second", name: "Second"), resumeWhenDisconnected: true)
    let store = AppStore(repository: repository, arguments: ["tests"]) { url in
        url == firstURL ? first : second
    }

    store.start()
    #expect(await eventually { store.phase == .connected && store.snapshot?.instance.id == "remote-first" })
    #expect(await eventuallyReceiving(first))

    store.selectInstance("local-second")
    #expect(await eventually { store.phase == .connected && store.snapshot?.instance.id == "remote-second" })
    #expect(await eventuallyReceiving(second))
    await first.failStaleReceive()
    try? await Task.sleep(nanoseconds: 50_000_000)

    #expect(store.selectedProfileID == "local-second")
    #expect(store.snapshot?.instance.id == "remote-second")
    #expect(store.phase == .connected)
    #expect(await first.disconnectCount > 0)
    store.applicationDidEnterBackground()
}

@MainActor
@Test func pairedProfilesRemainDistinctWhenBridgesAdvertiseTheSameID() throws {
    let firstURL = URL(string: "https://first.example.ts.net/sheltie")!
    let secondURL = URL(string: "https://second.example.ts.net/sheltie")!
    let remote = InstanceInfo(id: "copied-instance-id", name: "Bridge", host: "bridge.example.ts.net")
    let first = AppStore.profileForPairing(in: [], instance: remote, baseURL: firstURL, deviceID: "first-device")
    let second = AppStore.profileForPairing(in: [first], instance: remote, baseURL: secondURL, deviceID: "second-device")
    let repaired = AppStore.profileForPairing(in: [first, second], instance: remote, baseURL: firstURL, deviceID: "new-device")

    #expect(first.id != second.id)
    #expect(first.bridgeInstanceID == second.bridgeInstanceID)
    #expect(repaired.id == first.id)
    #expect(repaired.deviceID == "new-device")
    #expect(AppStore.sameEndpoint(firstURL, URL(string: "https://FIRST.example.ts.net:443/sheltie/")!))
}

@Test func legacyInstanceProfilesDecodeWithoutBridgeInstanceID() throws {
    let original = InstanceProfile(
        id: "legacy-id",
        displayName: "Legacy",
        baseURL: URL(string: "https://legacy.example.ts.net/sheltie")!,
        deviceID: "legacy-device"
    )
    let encoded = try JSONEncoder().encode(original)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "bridgeInstanceID")
    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(InstanceProfile.self, from: legacyData)

    #expect(decoded.id == original.id)
    #expect(decoded.bridgeInstanceID == nil)
}

@MainActor
@Test func selectingAgentMovesTheWholeNavigationContext() {
    let store = AppStore(repository: MemoryInstanceRepository(), arguments: ["tests", "--demo"])
    let agent = try! #require(store.snapshot?.agents.first { $0.id == "w2:p1" })

    store.selectAgent(agent)

    #expect(store.selectedWorkspaceID == "w2")
    #expect(store.selectedTabID == "w2:t1")
    #expect(store.selectedPaneID == "w2:p1")
    #expect(store.isSidebarPresented == false)
}

@MainActor
@Test func bridgeURLRequiresHTTPSExceptForLoopbackDebugging() throws {
    #expect(try AppStore.validatedBaseURL("https://studio.example.ts.net/sheltie").absoluteString == "https://studio.example.ts.net/sheltie")
    #expect(throws: BridgeClientError.self) {
        try AppStore.validatedBaseURL("ws://studio.example.ts.net/herdr.sock")
    }
    #expect(throws: BridgeClientError.self) {
        try AppStore.validatedBaseURL("https://studio.example.ts.net/sheltie?token=secret")
    }
#if DEBUG
    #expect(try AppStore.validatedBaseURL("http://127.0.0.1:9847").host == "127.0.0.1")
#endif
}

@Test func compactWorkspacePathsUseTheMinimumDisambiguatingParents() {
    func workspace(_ id: String, _ path: String?) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            id: id,
            number: 1,
            label: id,
            path: path,
            paneCount: 1,
            tabCount: 1,
            status: .idle,
            focused: false
        )
    }
    let labels = WorkspacePathLabels.make(for: [
        workspace("one", "/Users/example/dev/project"),
        workspace("two", "/Users/example/other/project"),
        workspace("three", "/Users/example/unique"),
        workspace("missing", nil),
    ])

    #expect(labels["one"] == "/dev/project")
    #expect(labels["two"] == "/other/project")
    #expect(labels["three"] == "/unique")
    #expect(labels["missing"] == nil)
}

@Test func sidebarSplitRatioPreservesUsefulSectionHeights() {
    #expect(SidebarSplitLayout.clampedRatio(0.42, totalHeight: 800) == 0.42)
    #expect(SidebarSplitLayout.clampedRatio(0, totalHeight: 800) == 0.225)
    #expect(SidebarSplitLayout.clampedRatio(1, totalHeight: 800) == 0.775)
    #expect(SidebarSplitLayout.clampedRatio(0, totalHeight: 300) == 0.35)
    #expect(SidebarSplitLayout.clampedRatio(.nan, totalHeight: 800) == 0.42)
}

@Test func deviceIdentitySignsPairingChallenge() throws {
    let service = "com.yannickherrero.SheltieTests.\(UUID().uuidString)"
    let keychain = KeychainStore(service: service)
    defer { try? keychain.remove("device-signing-key-v1") }
    let identity = try DeviceIdentity.loadOrCreate(keychain: keychain)
    let challenge = Data("pairing challenge".utf8)
    let signature = try P256.Signing.ECDSASignature(derRepresentation: identity.signature(for: challenge))
    let publicKey = try P256.Signing.PublicKey(derRepresentation: identity.publicKeyDER)

    #expect(publicKey.isValidSignature(signature, for: challenge))
}
