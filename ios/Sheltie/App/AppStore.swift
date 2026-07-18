import Combine
import Foundation
import SheltieProtocol
import UIKit

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var phase: ConnectionPhase = .noInstances
    @Published private(set) var profiles: [InstanceProfile]
    @Published var selectedProfileID: String?
    @Published private(set) var snapshot: BootstrapSnapshot?
    @Published private(set) var terminalFrames: [String: TerminalFrame] = [:]
    @Published private(set) var toast: ToastMessage?
    @Published var selectedWorkspaceID: String?
    @Published var selectedTabID: String?
    @Published var selectedPaneID: String?
    @Published var isSidebarPresented = false
    @Published var compactPaneID: String?

    private let repository: any InstancePersisting
    private let isDemo: Bool
    private var connectionTask: Task<Void, Never>?
    private var activeClient: BridgeClient?
    private var activeSessionToken: String?
    private var visiblePaneIDs = Set<String>()
    private var terminalColumns = 100
    private var terminalRows = 36

    init(
        repository: any InstancePersisting = InstanceRepository(),
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        self.repository = repository
        isDemo = arguments.contains("--demo") || arguments.contains("-sheltie-demo")
        if isDemo {
            let profile = InstanceProfile(
                id: DemoData.snapshot.instance.id,
                displayName: DemoData.snapshot.instance.name,
                baseURL: URL(string: "https://studio.example.ts.net/sheltie")!,
                deviceID: "demo",
                lastConnectedAt: Date()
            )
            profiles = [profile]
            selectedProfileID = profile.id
            apply(DemoData.snapshot)
            terminalFrames = DemoData.terminalFrames
            phase = .connected
        } else {
            profiles = repository.loadProfiles()
            let savedID = repository.loadSelectedID()
            selectedProfileID = profiles.contains(where: { $0.id == savedID }) ? savedID : profiles.first?.id
            phase = profiles.isEmpty ? .noInstances : .disconnected
        }
    }

    deinit {
        connectionTask?.cancel()
    }

    var selectedProfile: InstanceProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    var selectedWorkspace: WorkspaceSnapshot? {
        snapshot?.workspaces.first { $0.id == selectedWorkspaceID }
    }

    var selectedTab: TabSnapshot? {
        snapshot?.tabs.first { $0.id == selectedTabID }
    }

    var selectedPane: PaneSnapshot? {
        snapshot?.panes.first { $0.id == selectedPaneID }
    }

    func start() {
        guard !isDemo else { return }
        connectSelectedInstance()
    }

    func applicationDidBecomeActive() {
        guard !isDemo, phase != .connected else { return }
        connectSelectedInstance()
    }

    func applicationDidEnterBackground() {
        guard !isDemo else { return }
        connectionTask?.cancel()
        connectionTask = nil
        let client = activeClient
        activeClient = nil
        activeSessionToken = nil
        Task { await client?.disconnect() }
        phase = profiles.isEmpty ? .noInstances : .disconnected
    }

    func selectInstance(_ id: String) {
        guard id != selectedProfileID, profiles.contains(where: { $0.id == id }) else { return }
        selectedProfileID = id
        repository.saveSelectedID(id)
        snapshot = nil
        terminalFrames = [:]
        connectSelectedInstance()
    }

    func removeInstance(_ id: String) {
        profiles.removeAll { $0.id == id }
        try? repository.removeAccessToken(for: id)
        repository.saveProfiles(profiles)
        if selectedProfileID == id {
            selectedProfileID = profiles.first?.id
            repository.saveSelectedID(selectedProfileID)
            snapshot = nil
            terminalFrames = [:]
            connectionTask?.cancel()
            profiles.isEmpty ? (phase = .noInstances) : connectSelectedInstance()
        }
    }

    func beginPairing(baseURLString: String, deviceName: String? = nil) async throws -> PendingPairing {
        let baseURL = try Self.validatedBaseURL(baseURLString)
        let identity = try DeviceIdentity.loadOrCreate()
        let client = BridgeClient(baseURL: baseURL)
        let response = try await client.startPairing(
            deviceName: deviceName ?? UIDevice.current.name,
            publicKeyDER: identity.publicKeyDER
        )
        guard let challenge = Data(base64Encoded: response.challengeBase64) else {
            throw BridgeClientError.invalidResponse
        }
        return PendingPairing(
            baseURL: baseURL,
            pairingID: response.pairingID,
            challenge: challenge,
            expiresAt: Date(timeIntervalSince1970: Double(response.expiresAtMillis) / 1_000)
        )
    }

    func completePairing(_ pairing: PendingPairing, code: String) async throws {
        let identity = try DeviceIdentity.loadOrCreate()
        let signature = try identity.signature(for: pairing.challenge)
        let client = BridgeClient(baseURL: pairing.baseURL)
        let response = try await client.completePairing(
            pairingID: pairing.pairingID,
            code: code,
            signature: signature
        )
        let profile = InstanceProfile(
            id: response.instance.id,
            displayName: response.instance.name,
            baseURL: pairing.baseURL,
            deviceID: response.deviceID
        )
        profiles.removeAll { $0.id == profile.id }
        profiles.append(profile)
        repository.saveProfiles(profiles)
        try repository.setAccessToken(response.accessToken, for: profile.id)
        selectedProfileID = profile.id
        repository.saveSelectedID(profile.id)
        connectSelectedInstance()
    }

    func selectWorkspace(_ id: String) {
        guard let snapshot, let workspace = snapshot.workspaces.first(where: { $0.id == id }) else { return }
        selectedWorkspaceID = id
        selectedTabID = workspace.activeTabID ?? snapshot.tabs.first(where: { $0.workspaceID == id })?.id
        selectedPaneID = snapshot.layouts.first(where: { $0.tabID == selectedTabID })?.focusedPaneID
            ?? snapshot.panes.first(where: { $0.tabID == selectedTabID })?.id
        compactPaneID = selectedPaneID
        isSidebarPresented = false
        perform(.init(sessionID: activeSessionID, type: .focusWorkspace, targetID: id))
    }

    func selectTab(_ id: String) {
        guard let snapshot, let tab = snapshot.tabs.first(where: { $0.id == id }) else { return }
        selectedWorkspaceID = tab.workspaceID
        selectedTabID = id
        selectedPaneID = snapshot.layouts.first(where: { $0.tabID == id })?.focusedPaneID
            ?? snapshot.panes.first(where: { $0.tabID == id })?.id
        compactPaneID = selectedPaneID
        perform(.init(sessionID: activeSessionID, type: .focusTab, targetID: id))
    }

    func selectPane(_ id: String) {
        selectedPaneID = id
        compactPaneID = id
        perform(.init(sessionID: activeSessionID, type: .focusPane, targetID: id))
    }

    func selectAgent(_ agent: AgentSnapshot) {
        selectedWorkspaceID = agent.workspaceID
        selectedTabID = agent.tabID
        selectedPaneID = agent.paneID
        compactPaneID = agent.paneID
        isSidebarPresented = false
        perform(.init(sessionID: activeSessionID, type: .focusPane, targetID: agent.paneID))
    }

    func updateVisiblePanes(_ paneIDs: [String], columns: Int, rows: Int) {
        let ids = Set(paneIDs)
        let dimensionsChanged = columns != terminalColumns || rows != terminalRows
        guard ids != visiblePaneIDs || dimensionsChanged else { return }
        visiblePaneIDs = ids
        terminalColumns = max(20, columns)
        terminalRows = max(5, rows)
        sendSubscriptions()
    }

    func sendTerminalData(_ data: Data, to paneID: String) {
        perform(.init(
            sessionID: activeSessionID,
            type: .terminalInput,
            targetID: paneID,
            bytesBase64: data.base64EncodedString()
        ))
    }

    func sendTerminalText(_ text: String, to paneID: String) {
        guard !text.isEmpty else { return }
        perform(.init(sessionID: activeSessionID, type: .terminalInput, targetID: paneID, text: text))
    }

    func sendAgentMessage(_ text: String, to paneID: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        perform(.init(sessionID: activeSessionID, type: .agentMessage, targetID: paneID, text: text))
    }

    func sendKeys(_ keys: [String], to paneID: String? = nil) {
        guard let target = paneID ?? selectedPaneID, !keys.isEmpty else { return }
        perform(.init(sessionID: activeSessionID, type: .terminalKeys, targetID: target, keys: keys))
    }

    func dismissToast() {
        toast = nil
    }

    private var activeSessionID: String {
        snapshot?.activeSessionID ?? "default"
    }

    private func connectSelectedInstance() {
        connectionTask?.cancel()
        guard let profile = selectedProfile else {
            phase = .noInstances
            return
        }
        phase = .connecting
        connectionTask = Task { [weak self] in
            await self?.connectionLoop(profile: profile)
        }
    }

    private func connectionLoop(profile: InstanceProfile) async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                guard let accessToken = try repository.accessToken(for: profile.id) else {
                    throw BridgeClientError.server(status: 401, message: "This Mac must be paired again.")
                }
                let client = BridgeClient(baseURL: profile.baseURL)
                activeClient = client
                let credential = try await client.refreshSession(accessToken: accessToken)
                activeSessionToken = credential.sessionToken
                let initial = try await client.bootstrap(sessionID: nil, sessionToken: credential.sessionToken)
                apply(initial)
                phase = .connected
                attempt = 0
                try await client.connectStream(
                    sessionID: initial.activeSessionID ?? "default",
                    sessionToken: credential.sessionToken
                )
                sendSubscriptions()
                while !Task.isCancelled {
                    let message = try await client.receiveStreamMessage()
                    try await consume(message, client: client)
                }
                return
            } catch is CancellationError {
                return
            } catch {
                attempt += 1
                phase = attempt == 1
                    ? .failed(message: error.localizedDescription)
                    : .reconnecting(attempt: attempt)
                let delay = min(30.0, pow(2.0, Double(min(attempt, 5))))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func consume(_ message: StreamServerMessage, client: BridgeClient) async throws {
        switch message {
        case let .snapshot(snapshot):
            apply(snapshot)
        case let .terminalFrame(frame):
            if let previous = terminalFrames[frame.paneID], !frame.full, frame.sequence != previous.sequence + 1 {
                try await client.sendStreamMessage(.resync)
            } else {
                terminalFrames[frame.paneID] = frame
            }
        case let .terminalClosed(terminal):
            terminalFrames[terminal.paneID] = nil
            toast = ToastMessage(text: terminal.reason, isError: true)
        case let .actionResult(result):
            if !result.ok {
                toast = ToastMessage(text: result.message ?? "The action failed.", isError: true)
            }
        case .sessionExpiring:
            throw BridgeClientError.server(status: 401, message: "Refreshing the bridge session")
        case let .ping(id):
            try await client.sendStreamMessage(.pong(id: id))
        }
    }

    private func apply(_ newSnapshot: BootstrapSnapshot) {
        snapshot = newSnapshot
        let workspaceIDs = Set(newSnapshot.workspaces.map(\.id))
        if selectedWorkspaceID == nil || !workspaceIDs.contains(selectedWorkspaceID!) {
            selectedWorkspaceID = newSnapshot.focus.workspaceID ?? newSnapshot.workspaces.first?.id
        }
        let tabs = newSnapshot.tabs.filter { $0.workspaceID == selectedWorkspaceID }
        if selectedTabID == nil || !tabs.contains(where: { $0.id == selectedTabID }) {
            selectedTabID = newSnapshot.focus.tabID.flatMap { id in tabs.contains(where: { $0.id == id }) ? id : nil }
                ?? newSnapshot.workspaces.first(where: { $0.id == selectedWorkspaceID })?.activeTabID
                ?? tabs.first?.id
        }
        let panes = newSnapshot.panes.filter { $0.tabID == selectedTabID }
        if selectedPaneID == nil || !panes.contains(where: { $0.id == selectedPaneID }) {
            selectedPaneID = newSnapshot.focus.paneID.flatMap { id in panes.contains(where: { $0.id == id }) ? id : nil }
                ?? newSnapshot.layouts.first(where: { $0.tabID == selectedTabID })?.focusedPaneID
                ?? panes.first?.id
        }
        if compactPaneID == nil || !panes.contains(where: { $0.id == compactPaneID }) {
            compactPaneID = selectedPaneID
        }
        if let index = profiles.firstIndex(where: { $0.id == newSnapshot.instance.id }) {
            profiles[index].displayName = newSnapshot.instance.name
            profiles[index].lastConnectedAt = Date()
            if !isDemo { repository.saveProfiles(profiles) }
        }
    }

    private func sendSubscriptions() {
        guard !isDemo, let client = activeClient, phase.isConnected else { return }
        let sessionID = activeSessionID
        let subscriptions = visiblePaneIDs.map {
            TerminalSubscription(
                sessionID: sessionID,
                paneID: $0,
                columns: terminalColumns,
                rows: terminalRows,
                writable: $0 == selectedPaneID
            )
        }
        Task {
            try? await client.sendStreamMessage(.subscribe(subscriptions))
        }
    }

    private func perform(_ action: ActionCommand) {
        guard !isDemo else {
            toast = ToastMessage(text: "Demo mode · action not sent", isError: false)
            return
        }
        guard let client = activeClient, phase.isConnected else {
            toast = ToastMessage(text: "The Mac is not connected.", isError: true)
            return
        }
        Task {
            do {
                try await client.sendStreamMessage(.action(action))
            } catch {
                toast = ToastMessage(text: error.localizedDescription, isError: true)
            }
        }
    }

    static func validatedBaseURL(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty,
              components.query == nil,
              components.fragment == nil else {
            throw BridgeClientError.invalidBaseURL
        }
#if DEBUG
        let permitsLocalHTTP = scheme == "http" && (host == "127.0.0.1" || host == "localhost")
#else
        let permitsLocalHTTP = false
#endif
        guard scheme == "https" || permitsLocalHTTP else { throw BridgeClientError.invalidBaseURL }
        components.scheme = scheme
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .isEmpty ? "" : "/" + components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = components.url else { throw BridgeClientError.invalidBaseURL }
        return url
    }
}
