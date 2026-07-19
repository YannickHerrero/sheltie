import Combine
import Foundation
import SheltieProtocol
import UIKit
import UserNotifications

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var phase: ConnectionPhase = .noInstances
    @Published private(set) var profiles: [InstanceProfile]
    @Published var selectedProfileID: String?
    @Published var selectedSessionID: String?
    @Published private(set) var snapshot: BootstrapSnapshot?
    @Published private(set) var terminalFrames: [String: TerminalFrame] = [:]
    @Published private(set) var terminalHistories: [String: TerminalHistory] = [:]
    @Published private(set) var terminalHistoryLoadingPaneIDs = Set<String>()
    @Published private(set) var workspaceTodos: [String: WorkspaceTodoDocument] = [:]
    @Published private(set) var workspaceTodoLoadingIDs = Set<String>()
    @Published private(set) var workspaceTodoSavingIDs = Set<String>()
    @Published private(set) var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var notificationProviderConfigured = false
    @Published private(set) var notificationErrorMessage: String?
    @Published private(set) var doneNotificationsEnabled = UserDefaults.standard.bool(forKey: "notifications.doneEnabled")
    @Published private(set) var blockedNotificationsEnabled = UserDefaults.standard.bool(forKey: "notifications.blockedEnabled")
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
    private var terminalViewports: [String: TerminalViewport] = [:]
    private var terminalHistoryRequestIDs: [String: String] = [:]
    private var terminalHistoryCacheOrder: [String] = []
    private var workspaceTodoRequestIDs: [String: String] = [:]
    private var notificationRequestID: String?
    private var notificationDeviceToken = UserDefaults.standard.string(forKey: "notifications.deviceToken")
    private var notificationObservers: [NSObjectProtocol] = []

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
            selectedSessionID = DemoData.snapshot.activeSessionID
            apply(DemoData.snapshot)
            terminalFrames = DemoData.terminalFrames
            phase = .connected
        } else {
            profiles = repository.loadProfiles()
            let savedID = repository.loadSelectedID()
            selectedProfileID = profiles.contains(where: { $0.id == savedID }) ? savedID : profiles.first?.id
            phase = profiles.isEmpty ? .noInstances : .disconnected
        }
        configureNotificationObservers()
    }

    deinit {
        connectionTask?.cancel()
        for observer in notificationObservers { NotificationCenter.default.removeObserver(observer) }
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
        refreshNotificationAuthorization()
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
        resetTerminalHistory()
        resetWorkspaceTodos()
        Task { await client?.disconnect() }
        phase = profiles.isEmpty ? .noInstances : .disconnected
    }

    func selectSession(_ id: String) {
        guard id != selectedSessionID,
              storeSessions.contains(where: { $0.id == id && $0.reachable }) else { return }
        selectedSessionID = id
        snapshot = nil
        terminalFrames = [:]
        resetTerminalHistory()
        resetWorkspaceTodos()
        connectSelectedInstance()
    }

    func selectInstance(_ id: String) {
        guard id != selectedProfileID, profiles.contains(where: { $0.id == id }) else { return }
        selectedProfileID = id
        selectedSessionID = nil
        repository.saveSelectedID(id)
        snapshot = nil
        terminalFrames = [:]
        resetTerminalHistory()
        resetWorkspaceTodos()
        connectSelectedInstance()
    }

    func removeInstance(_ id: String) {
        profiles.removeAll { $0.id == id }
        try? repository.removeAccessToken(for: id)
        repository.saveProfiles(profiles)
        if selectedProfileID == id {
            selectedProfileID = profiles.first?.id
            selectedSessionID = nil
            repository.saveSelectedID(selectedProfileID)
            snapshot = nil
            terminalFrames = [:]
            resetTerminalHistory()
            resetWorkspaceTodos()
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
        selectedSessionID = nil
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
        sendSubscriptions()
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

    func updateVisiblePanes(_ paneIDs: [String]) {
        let ids = Set(paneIDs)
        guard ids != visiblePaneIDs else { return }
        visiblePaneIDs = ids
        sendSubscriptions()
    }

    func updateTerminalSize(paneID: String, columns: Int, rows: Int) {
        let viewport = TerminalViewport(columns: max(20, columns), rows: max(5, rows))
        guard terminalViewports[paneID] != viewport else { return }
        terminalViewports[paneID] = viewport
        if visiblePaneIDs.contains(paneID) { sendSubscriptions() }
    }

    @discardableResult
    func requestWorkspaceTodo(for workspaceID: String) -> String? {
        guard snapshot?.workspaces.contains(where: { $0.id == workspaceID }) == true else { return nil }
        guard snapshot?.bridge.capabilities.contains("workspace.todo") == true else {
            toast = ToastMessage(text: "Update the Sheltie bridge to edit todo.md.", isError: true)
            return nil
        }
        let requestID = UUID().uuidString
        workspaceTodoRequestIDs[workspaceID] = requestID
        workspaceTodoLoadingIDs.insert(workspaceID)
        if isDemo {
            workspaceTodos[workspaceID] = DemoData.workspaceTodo(workspaceID: workspaceID, requestID: requestID)
            workspaceTodoLoadingIDs.remove(workspaceID)
            workspaceTodoRequestIDs[workspaceID] = nil
            return requestID
        }
        guard let client = activeClient, phase.isConnected else {
            workspaceTodoLoadingIDs.remove(workspaceID)
            workspaceTodoRequestIDs[workspaceID] = nil
            toast = ToastMessage(text: "The Mac is not connected.", isError: true)
            return nil
        }
        let request = WorkspaceTodoReadRequest(requestID: requestID, sessionID: activeSessionID, workspaceID: workspaceID)
        Task {
            do {
                try await client.sendStreamMessage(.workspaceTodoRead(request))
            } catch {
                guard workspaceTodoRequestIDs[workspaceID] == requestID else { return }
                workspaceTodoLoadingIDs.remove(workspaceID)
                workspaceTodoRequestIDs[workspaceID] = nil
                toast = ToastMessage(text: "todo.md is unavailable.", isError: true)
            }
        }
        return requestID
    }

    @discardableResult
    func saveWorkspaceTodo(
        workspaceID: String,
        content: String,
        expectedRevision: String?,
        force: Bool = false
    ) -> String? {
        guard snapshot?.bridge.capabilities.contains("workspace.todo") == true else { return nil }
        let requestID = UUID().uuidString
        workspaceTodoRequestIDs[workspaceID] = requestID
        workspaceTodoSavingIDs.insert(workspaceID)
        if isDemo {
            workspaceTodos[workspaceID] = WorkspaceTodoDocument(
                requestID: requestID,
                sessionID: activeSessionID,
                workspaceID: workspaceID,
                exists: true,
                content: content,
                revision: UUID().uuidString,
                modifiedAtMillis: Int64(Date().timeIntervalSince1970 * 1_000)
            )
            workspaceTodoSavingIDs.remove(workspaceID)
            workspaceTodoRequestIDs[workspaceID] = nil
            return requestID
        }
        guard let client = activeClient, phase.isConnected else {
            workspaceTodoSavingIDs.remove(workspaceID)
            workspaceTodoRequestIDs[workspaceID] = nil
            return nil
        }
        let request = WorkspaceTodoSaveRequest(
            requestID: requestID,
            sessionID: activeSessionID,
            workspaceID: workspaceID,
            content: content,
            expectedRevision: expectedRevision,
            force: force
        )
        Task {
            do {
                try await client.sendStreamMessage(.workspaceTodoSave(request))
            } catch {
                guard workspaceTodoRequestIDs[workspaceID] == requestID else { return }
                workspaceTodoSavingIDs.remove(workspaceID)
                workspaceTodoRequestIDs[workspaceID] = nil
                toast = ToastMessage(text: "todo.md could not be saved.", isError: true)
            }
        }
        return requestID
    }

    func requestTerminalHistory(for paneID: String) {
        guard snapshot?.panes.contains(where: { $0.id == paneID }) == true else { return }
        guard snapshot?.bridge.capabilities.contains("terminal.history") == true else {
            toast = ToastMessage(text: "Update the Sheltie bridge to view terminal history.", isError: true)
            return
        }
        let requestID = UUID().uuidString
        terminalHistoryRequestIDs[paneID] = requestID
        terminalHistoryLoadingPaneIDs.insert(paneID)

        if isDemo {
            cacheTerminalHistory(DemoData.terminalHistory(paneID: paneID, requestID: requestID))
            terminalHistoryLoadingPaneIDs.remove(paneID)
            terminalHistoryRequestIDs[paneID] = nil
            return
        }
        guard let client = activeClient, phase.isConnected else {
            terminalHistoryLoadingPaneIDs.remove(paneID)
            terminalHistoryRequestIDs[paneID] = nil
            toast = ToastMessage(text: "The Mac is not connected.", isError: true)
            return
        }
        let request = TerminalHistoryRequest(
            requestID: requestID,
            sessionID: activeSessionID,
            paneID: paneID,
            lines: 1_000
        )
        Task {
            do {
                try await client.sendStreamMessage(.terminalHistoryRequest(request))
            } catch {
                guard terminalHistoryRequestIDs[paneID] == requestID else { return }
                terminalHistoryLoadingPaneIDs.remove(paneID)
                terminalHistoryRequestIDs[paneID] = nil
                toast = ToastMessage(text: "Terminal history is unavailable.", isError: true)
            }
        }
    }

    func sendTerminalData(_ data: Data, to paneID: String) {
        perform(.init(
            sessionID: activeSessionID,
            type: .terminalInput,
            targetID: paneID,
            bytesBase64: data.base64EncodedString()
        ))
    }

    func sendTerminalCommand(_ text: String, to paneID: String) {
        guard !text.isEmpty else { return }
        perform(.init(
            sessionID: activeSessionID,
            type: .terminalInput,
            targetID: paneID,
            text: text,
            keys: ["Enter"]
        ))
    }

    func sendAgentMessage(_ text: String, to paneID: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        perform(.init(sessionID: activeSessionID, type: .agentMessage, targetID: paneID, text: text))
    }

    func sendKeys(_ keys: [String], to paneID: String? = nil) {
        guard let target = paneID ?? selectedPaneID, !keys.isEmpty else { return }
        perform(.init(sessionID: activeSessionID, type: .terminalKeys, targetID: target, keys: keys))
    }

    func createWorkspace(cwd: String, label: String?) {
        guard !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        perform(.init(
            sessionID: activeSessionID,
            type: .createWorkspace,
            label: label?.trimmingCharacters(in: .whitespacesAndNewlines),
            cwd: cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
    }

    func renameWorkspace(_ id: String, label: String) {
        let value = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        perform(.init(sessionID: activeSessionID, type: .renameWorkspace, targetID: id, label: value))
    }

    func closeWorkspace(_ id: String) {
        perform(.init(sessionID: activeSessionID, type: .closeWorkspace, targetID: id))
    }

    func createTab() {
        guard let workspaceID = selectedWorkspaceID else { return }
        perform(.init(sessionID: activeSessionID, type: .createTab, targetID: workspaceID))
    }

    func renameTab(_ id: String, label: String) {
        let value = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        perform(.init(sessionID: activeSessionID, type: .renameTab, targetID: id, label: value))
    }

    func closeTab(_ id: String) {
        perform(.init(sessionID: activeSessionID, type: .closeTab, targetID: id))
    }

    func splitSelectedPane(_ direction: SplitDirection) {
        guard let paneID = selectedPaneID else { return }
        perform(.init(
            sessionID: activeSessionID,
            type: .splitPane,
            targetID: paneID,
            splitDirection: direction,
            ratio: 0.5
        ))
    }

    func setSplitRatio(tabID: String, path: [Bool], ratio: Double) {
        perform(.init(
            sessionID: activeSessionID,
            type: .setSplitRatio,
            targetID: tabID,
            ratio: ratio,
            splitPath: path
        ))
    }

    func zoomSelectedPane() {
        guard let paneID = selectedPaneID else { return }
        perform(.init(sessionID: activeSessionID, type: .zoomPane, targetID: paneID))
    }

    func renamePane(_ id: String, label: String?) {
        perform(.init(sessionID: activeSessionID, type: .renamePane, targetID: id, label: label))
    }

    func movePane(_ id: String, to tabID: String) {
        perform(.init(
            sessionID: activeSessionID,
            type: .movePane,
            targetID: id,
            moveDestination: .tab(tabID: tabID, targetPaneID: nil, split: .horizontal)
        ))
    }

    func movePaneToNewTab(_ id: String, workspaceID: String) {
        perform(.init(
            sessionID: activeSessionID,
            type: .movePane,
            targetID: id,
            moveDestination: .newTab(workspaceID: workspaceID, label: nil)
        ))
    }

    func closeSelectedPane() {
        guard let paneID = selectedPaneID else { return }
        perform(.init(sessionID: activeSessionID, type: .closePane, targetID: paneID))
    }

    func selectNextTab() {
        guard let snapshot else { return }
        let tabs = snapshot.tabs.filter { $0.workspaceID == selectedWorkspaceID }
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex { $0.id == selectedTabID } ?? -1
        selectTab(tabs[(index + 1) % tabs.count].id)
    }

    func selectNextPane() {
        guard let snapshot else { return }
        let panes = snapshot.panes.filter { $0.tabID == selectedTabID }
        guard !panes.isEmpty else { return }
        let index = panes.firstIndex { $0.id == selectedPaneID } ?? -1
        selectPane(panes[(index + 1) % panes.count].id)
    }

    func toggleSidebar() {
        isSidebarPresented.toggle()
    }

    func retryConnection() {
        connectSelectedInstance()
    }

    func dismissToast() {
        toast = nil
    }

    func setDoneNotificationsEnabled(_ enabled: Bool) {
        doneNotificationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "notifications.doneEnabled")
        updateNotificationAuthorizationIfNeeded(enabling: enabled)
    }

    func setBlockedNotificationsEnabled(_ enabled: Bool) {
        blockedNotificationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "notifications.blockedEnabled")
        updateNotificationAuthorizationIfNeeded(enabling: enabled)
    }

    func refreshNotificationAuthorization() {
        if isDemo {
            notificationAuthorizationStatus = .authorized
            notificationProviderConfigured = true
            return
        }
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationAuthorizationStatus = settings.authorizationStatus
            if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func openSystemNotificationSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
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
                let initial = try await client.bootstrap(sessionID: selectedSessionID, sessionToken: credential.sessionToken)
                apply(initial)
                phase = .connected
                attempt = 0
                try await client.connectStream(
                    sessionID: initial.activeSessionID ?? "default",
                    sessionToken: credential.sessionToken
                )
                sendSubscriptions()
                sendNotificationConfiguration()
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
        case let .notificationConfiguration(configuration):
            guard configuration.requestID == notificationRequestID else { return }
            notificationRequestID = nil
            notificationProviderConfigured = configuration.providerConfigured
            notificationErrorMessage = configuration.errorMessage
        case let .workspaceTodo(document):
            guard workspaceTodoRequestIDs[document.workspaceID] == document.requestID,
                  document.sessionID == activeSessionID else { return }
            workspaceTodoLoadingIDs.remove(document.workspaceID)
            workspaceTodoSavingIDs.remove(document.workspaceID)
            workspaceTodoRequestIDs[document.workspaceID] = nil
            workspaceTodos[document.workspaceID] = document
        case let .terminalHistory(history):
            guard terminalHistoryRequestIDs[history.paneID] == history.requestID,
                  history.sessionID == activeSessionID else { return }
            terminalHistoryLoadingPaneIDs.remove(history.paneID)
            terminalHistoryRequestIDs[history.paneID] = nil
            if history.bytes != nil {
                cacheTerminalHistory(history)
            } else {
                toast = ToastMessage(text: history.errorMessage ?? "Terminal history is unavailable.", isError: true)
            }
        case let .terminalClosed(terminal):
            terminalFrames[terminal.paneID] = nil
            terminalHistories[terminal.paneID] = nil
            terminalHistoryLoadingPaneIDs.remove(terminal.paneID)
            terminalHistoryRequestIDs[terminal.paneID] = nil
            terminalHistoryCacheOrder.removeAll { $0 == terminal.paneID }
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

    private func cacheTerminalHistory(_ history: TerminalHistory) {
        terminalHistories[history.paneID] = history
        terminalHistoryCacheOrder.removeAll { $0 == history.paneID }
        terminalHistoryCacheOrder.append(history.paneID)
        while terminalHistoryCacheOrder.count > 8 {
            terminalHistories[terminalHistoryCacheOrder.removeFirst()] = nil
        }
    }

    private func resetTerminalHistory() {
        terminalHistories = [:]
        terminalHistoryLoadingPaneIDs = []
        terminalHistoryRequestIDs = [:]
        terminalHistoryCacheOrder = []
    }

    private func resetWorkspaceTodos() {
        workspaceTodos = [:]
        workspaceTodoLoadingIDs = []
        workspaceTodoSavingIDs = []
        workspaceTodoRequestIDs = [:]
    }

    private var storeSessions: [SessionSummary] {
        snapshot?.sessions ?? []
    }

    private func apply(_ newSnapshot: BootstrapSnapshot) {
        snapshot = newSnapshot
        if !newSnapshot.bridge.capabilities.contains("notifications.apns") {
            notificationProviderConfigured = false
        }
        selectedSessionID = newSnapshot.activeSessionID
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

    private func configureNotificationObservers() {
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: SheltieNotificationEvents.deviceToken,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let token = notification.object as? String else { return }
            Task { @MainActor [weak self] in
                self?.notificationDeviceToken = token
                UserDefaults.standard.set(token, forKey: "notifications.deviceToken")
                self?.notificationErrorMessage = nil
                self?.sendNotificationConfiguration()
            }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: SheltieNotificationEvents.registrationFailed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.notificationErrorMessage = "This device could not register with Apple Push Notification service."
            }
        })
    }

    private func updateNotificationAuthorizationIfNeeded(enabling: Bool) {
        notificationErrorMessage = nil
        if isDemo {
            notificationAuthorizationStatus = .authorized
            notificationProviderConfigured = true
            return
        }
        guard enabling, notificationAuthorizationStatus == .notDetermined else {
            sendNotificationConfiguration()
            return
        }
        Task {
            do {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                notificationAuthorizationStatus = settings.authorizationStatus
                if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                    UIApplication.shared.registerForRemoteNotifications()
                } else {
                    sendNotificationConfiguration()
                }
            } catch {
                notificationErrorMessage = "Notification permission could not be requested."
            }
        }
    }

    private func sendNotificationConfiguration() {
        guard !isDemo,
              let client = activeClient,
              phase.isConnected,
              snapshot?.bridge.capabilities.contains("notifications.apns") == true else {
            notificationProviderConfigured = isDemo
            return
        }
        let requestID = UUID().uuidString
        notificationRequestID = requestID
        let authorized = notificationAuthorizationStatus == .authorized || notificationAuthorizationStatus == .provisional
        let request = NotificationRegistrationRequest(
            requestID: requestID,
            deviceToken: authorized ? notificationDeviceToken : nil,
            doneEnabled: doneNotificationsEnabled,
            blockedEnabled: blockedNotificationsEnabled
        )
        Task {
            do {
                try await client.sendStreamMessage(.configureNotifications(request))
            } catch {
                guard notificationRequestID == requestID else { return }
                notificationRequestID = nil
                notificationErrorMessage = "Notification settings could not reach the Mac."
            }
        }
    }

    private func sendSubscriptions() {
        guard !isDemo, let client = activeClient, phase.isConnected else { return }
        let sessionID = activeSessionID
        let subscriptions = visiblePaneIDs.map { paneID in
            let viewport = terminalViewports[paneID] ?? .fallback
            return TerminalSubscription(
                sessionID: sessionID,
                paneID: paneID,
                columns: viewport.columns,
                rows: viewport.rows,
                writable: paneID == selectedPaneID
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
