import Combine
import Foundation
import SheltieProtocol
import UIKit
import UserNotifications

struct WorkspaceFileLocation: Hashable {
    let workspaceID: String
    let relativePath: String
}

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
    @Published private(set) var workspaceDirectories: [WorkspaceFileLocation: WorkspaceDirectoryListing] = [:]
    @Published private(set) var workspaceFiles: [WorkspaceFileLocation: WorkspaceFileDocument] = [:]
    @Published private(set) var workspaceDirectoryLoadingLocations = Set<WorkspaceFileLocation>()
    @Published private(set) var workspaceFileLoadingLocations = Set<WorkspaceFileLocation>()
    @Published private(set) var workspaceFileSavingLocations = Set<WorkspaceFileLocation>()
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
    private let clientFactory: @Sendable (URL) -> any BridgeConnecting
    private var connectionTask: Task<Void, Never>?
    private var connectionGeneration = 0
    private var activeClient: (any BridgeConnecting)?
    private var activeSessionToken: String?
    private var visiblePaneIDs = Set<String>()
    private var terminalViewports: [String: TerminalViewport] = [:]
    private var terminalHistoryRequestIDs: [String: String] = [:]
    private var terminalHistoryCacheOrder: [String] = []
    private var workspaceTodoRequestIDs: [String: String] = [:]
    private var workspaceDirectoryRequestIDs: [WorkspaceFileLocation: String] = [:]
    private var workspaceFileRequestIDs: [WorkspaceFileLocation: String] = [:]
    private var notificationRequestID: String?
    private var notificationDeviceToken = UserDefaults.standard.string(forKey: "notifications.deviceToken")
    private var notificationObservers: [NSObjectProtocol] = []

    init(
        repository: any InstancePersisting = InstanceRepository(),
        arguments: [String] = ProcessInfo.processInfo.arguments,
        clientFactory: @escaping @Sendable (URL) -> any BridgeConnecting = { BridgeClient(baseURL: $0) }
    ) {
        self.repository = repository
        self.clientFactory = clientFactory
        isDemo = arguments.contains("--demo") || arguments.contains("-sheltie-demo")
        if isDemo {
            let profile = InstanceProfile(
                id: DemoData.snapshot.instance.id,
                displayName: DemoData.snapshot.instance.name,
                baseURL: URL(string: "https://studio.example.ts.net/sheltie")!,
                deviceID: "demo",
                bridgeInstanceID: DemoData.snapshot.instance.id,
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
        invalidateConnection()
        resetHostContent()
        phase = profiles.isEmpty ? .noInstances : .disconnected
    }

    func selectSession(_ id: String) {
        guard id != selectedSessionID,
              storeSessions.contains(where: { $0.id == id && $0.reachable }) else { return }
        selectedSessionID = id
        resetHostContent(preservingSelectedSession: true)
        connectSelectedInstance()
    }

    func selectInstance(_ id: String) {
        guard id != selectedProfileID, profiles.contains(where: { $0.id == id }) else { return }
        activateProfile(id)
    }

    func removeInstance(_ id: String) {
        profiles.removeAll { $0.id == id }
        try? repository.removeAccessToken(for: id)
        repository.saveProfiles(profiles)
        guard selectedProfileID == id else { return }
        if let nextID = profiles.first?.id {
            activateProfile(nextID)
        } else {
            selectedProfileID = nil
            selectedSessionID = nil
            repository.saveSelectedID(nil)
            invalidateConnection()
            resetHostContent()
            phase = .noInstances
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
        let profile = Self.profileForPairing(
            in: profiles,
            instance: response.instance,
            baseURL: pairing.baseURL,
            deviceID: response.deviceID
        )
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        repository.saveProfiles(profiles)
        try repository.setAccessToken(response.accessToken, for: profile.id)
        activateProfile(profile.id)
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
            toast = ToastMessage(text: "The host is not connected.", isError: true)
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

    func workspaceDirectory(workspaceID: String, relativePath: String) -> WorkspaceDirectoryListing? {
        workspaceDirectories[.init(workspaceID: workspaceID, relativePath: relativePath)]
    }

    func workspaceFile(workspaceID: String, relativePath: String) -> WorkspaceFileDocument? {
        workspaceFiles[.init(workspaceID: workspaceID, relativePath: relativePath)]
    }

    @discardableResult
    func requestWorkspaceDirectory(workspaceID: String, relativePath: String) -> String? {
        guard snapshot?.workspaces.contains(where: { $0.id == workspaceID }) == true else { return nil }
        guard snapshot?.bridge.capabilities.contains("workspace.files") == true else {
            toast = ToastMessage(text: "Update the Sheltie bridge to browse files.", isError: true)
            return nil
        }
        let location = WorkspaceFileLocation(workspaceID: workspaceID, relativePath: relativePath)
        let requestID = UUID().uuidString
        workspaceDirectoryRequestIDs[location] = requestID
        workspaceDirectoryLoadingLocations.insert(location)
        if isDemo {
            workspaceDirectories[location] = DemoData.workspaceDirectory(
                workspaceID: workspaceID,
                relativePath: relativePath,
                requestID: requestID
            )
            workspaceDirectoryLoadingLocations.remove(location)
            workspaceDirectoryRequestIDs[location] = nil
            return requestID
        }
        guard let client = activeClient, phase.isConnected else {
            workspaceDirectoryLoadingLocations.remove(location)
            workspaceDirectoryRequestIDs[location] = nil
            toast = ToastMessage(text: "The host is not connected.", isError: true)
            return nil
        }
        let request = WorkspaceDirectoryListRequest(
            requestID: requestID,
            sessionID: activeSessionID,
            workspaceID: workspaceID,
            relativePath: relativePath
        )
        Task {
            do {
                try await client.sendStreamMessage(.workspaceDirectoryList(request))
            } catch {
                guard workspaceDirectoryRequestIDs[location] == requestID else { return }
                workspaceDirectoryLoadingLocations.remove(location)
                workspaceDirectoryRequestIDs[location] = nil
                toast = ToastMessage(text: "The directory is unavailable.", isError: true)
            }
        }
        return requestID
    }

    @discardableResult
    func requestWorkspaceFile(workspaceID: String, relativePath: String) -> String? {
        guard snapshot?.workspaces.contains(where: { $0.id == workspaceID }) == true else { return nil }
        guard snapshot?.bridge.capabilities.contains("workspace.files") == true else {
            toast = ToastMessage(text: "Update the Sheltie bridge to edit files.", isError: true)
            return nil
        }
        let location = WorkspaceFileLocation(workspaceID: workspaceID, relativePath: relativePath)
        let requestID = UUID().uuidString
        workspaceFileRequestIDs[location] = requestID
        workspaceFileLoadingLocations.insert(location)
        if isDemo {
            workspaceFiles[location] = DemoData.workspaceFile(
                workspaceID: workspaceID,
                relativePath: relativePath,
                requestID: requestID
            )
            workspaceFileLoadingLocations.remove(location)
            workspaceFileRequestIDs[location] = nil
            return requestID
        }
        guard let client = activeClient, phase.isConnected else {
            workspaceFileLoadingLocations.remove(location)
            workspaceFileRequestIDs[location] = nil
            toast = ToastMessage(text: "The host is not connected.", isError: true)
            return nil
        }
        let request = WorkspaceFileReadRequest(
            requestID: requestID,
            sessionID: activeSessionID,
            workspaceID: workspaceID,
            relativePath: relativePath
        )
        Task {
            do {
                try await client.sendStreamMessage(.workspaceFileRead(request))
            } catch {
                guard workspaceFileRequestIDs[location] == requestID else { return }
                workspaceFileLoadingLocations.remove(location)
                workspaceFileRequestIDs[location] = nil
                toast = ToastMessage(text: "The file is unavailable.", isError: true)
            }
        }
        return requestID
    }

    @discardableResult
    func saveWorkspaceFile(
        _ document: WorkspaceFileDocument,
        content: String,
        force: Bool = false
    ) -> String? {
        guard snapshot?.bridge.capabilities.contains("workspace.files") == true,
              let documentID = document.documentID else { return nil }
        let bytes = Data(content.utf8)
        guard bytes.count <= 1024 * 1024 else {
            toast = ToastMessage(text: "The file exceeds the 1 MiB editing limit.", isError: true)
            return nil
        }
        let location = WorkspaceFileLocation(
            workspaceID: document.workspaceID,
            relativePath: document.relativePath
        )
        let requestID = UUID().uuidString
        workspaceFileRequestIDs[location] = requestID
        workspaceFileSavingLocations.insert(location)
        if isDemo {
            workspaceFiles[location] = WorkspaceFileDocument(
                requestID: requestID,
                sessionID: activeSessionID,
                workspaceID: document.workspaceID,
                documentID: documentID,
                relativePath: document.relativePath,
                exists: true,
                contentBase64: bytes.base64EncodedString(),
                revision: UUID().uuidString,
                modifiedAtMillis: Int64(Date().timeIntervalSince1970 * 1_000),
                mode: document.mode
            )
            workspaceFileSavingLocations.remove(location)
            workspaceFileRequestIDs[location] = nil
            return requestID
        }
        guard let client = activeClient, phase.isConnected else {
            workspaceFileSavingLocations.remove(location)
            workspaceFileRequestIDs[location] = nil
            toast = ToastMessage(text: "The host is not connected.", isError: true)
            return nil
        }
        let request = WorkspaceFileSaveRequest(
            requestID: requestID,
            sessionID: activeSessionID,
            workspaceID: document.workspaceID,
            documentID: documentID,
            relativePath: document.relativePath,
            contentBase64: bytes.base64EncodedString(),
            expectedRevision: document.revision,
            force: force
        )
        Task {
            do {
                try await client.sendStreamMessage(.workspaceFileSave(request))
            } catch {
                guard workspaceFileRequestIDs[location] == requestID else { return }
                workspaceFileSavingLocations.remove(location)
                workspaceFileRequestIDs[location] = nil
                toast = ToastMessage(text: "The file could not be saved.", isError: true)
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
            toast = ToastMessage(text: "The host is not connected.", isError: true)
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

    func createWorkspace() {
        perform(.init(sessionID: activeSessionID, type: .createWorkspace))
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

    private func activateProfile(_ id: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        selectedProfileID = id
        selectedSessionID = nil
        repository.saveSelectedID(id)
        resetHostContent()
        connectSelectedInstance()
    }

    @discardableResult
    private func invalidateConnection() -> Int {
        connectionGeneration &+= 1
        connectionTask?.cancel()
        connectionTask = nil
        let client = activeClient
        activeClient = nil
        activeSessionToken = nil
        notificationRequestID = nil
        Task { await client?.disconnect() }
        return connectionGeneration
    }

    private func isCurrentConnection(_ generation: Int, profileID: String) -> Bool {
        generation == connectionGeneration && selectedProfileID == profileID
    }

    private func resetHostContent(preservingSelectedSession: Bool = false) {
        if !preservingSelectedSession { selectedSessionID = nil }
        snapshot = nil
        terminalFrames = [:]
        selectedWorkspaceID = nil
        selectedTabID = nil
        selectedPaneID = nil
        compactPaneID = nil
        visiblePaneIDs = []
        terminalViewports = [:]
        resetTerminalHistory()
        resetWorkspaceTodos()
        notificationProviderConfigured = false
        notificationErrorMessage = nil
        notificationRequestID = nil
        toast = nil
    }

    static func profileForPairing(
        in profiles: [InstanceProfile],
        instance: InstanceInfo,
        baseURL: URL,
        deviceID: String
    ) -> InstanceProfile {
        let existing = profiles.first { sameEndpoint($0.baseURL, baseURL) }
        return InstanceProfile(
            id: existing?.id ?? UUID().uuidString,
            displayName: instance.name,
            baseURL: baseURL,
            deviceID: deviceID,
            bridgeInstanceID: instance.id,
            lastConnectedAt: existing?.lastConnectedAt
        )
    }

    static func sameEndpoint(_ lhs: URL, _ rhs: URL) -> Bool {
        func components(_ url: URL) -> (String, String, Int?, String) {
            let scheme = url.scheme?.lowercased() ?? ""
            let host = url.host?.lowercased() ?? ""
            let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
            let path = url.path.split(separator: "/").joined(separator: "/")
            return (scheme, host, url.port ?? defaultPort, path)
        }
        let left = components(lhs)
        let right = components(rhs)
        return left.0 == right.0 && left.1 == right.1 && left.2 == right.2 && left.3 == right.3
    }

    private func connectSelectedInstance() {
        let generation = invalidateConnection()
        guard let profile = selectedProfile else {
            phase = .noInstances
            return
        }
        phase = .connecting
        connectionTask = Task { [weak self] in
            await self?.connectionLoop(profile: profile, generation: generation)
        }
    }

    private func connectionLoop(profile: InstanceProfile, generation: Int) async {
        var attempt = 0
        while isCurrentConnection(generation, profileID: profile.id), !Task.isCancelled {
            var client: (any BridgeConnecting)?
            do {
                guard let accessToken = try repository.accessToken(for: profile.id) else {
                    throw BridgeClientError.server(status: 401, message: "This host must be paired again.")
                }
                guard isCurrentConnection(generation, profileID: profile.id) else { return }
                let candidate = clientFactory(profile.baseURL)
                client = candidate
                activeClient = candidate
                let credential = try await candidate.refreshSession(accessToken: accessToken)
                guard isCurrentConnection(generation, profileID: profile.id) else {
                    await candidate.disconnect()
                    return
                }
                activeSessionToken = credential.sessionToken
                let initial = try await candidate.bootstrap(
                    sessionID: selectedSessionID,
                    sessionToken: credential.sessionToken
                )
                guard isCurrentConnection(generation, profileID: profile.id) else {
                    await candidate.disconnect()
                    return
                }
                apply(initial)
                phase = .connected
                attempt = 0
                try await candidate.connectStream(
                    sessionID: initial.activeSessionID ?? "default",
                    sessionToken: credential.sessionToken
                )
                guard isCurrentConnection(generation, profileID: profile.id) else {
                    await candidate.disconnect()
                    return
                }
                sendSubscriptions()
                sendNotificationConfiguration()
                while isCurrentConnection(generation, profileID: profile.id), !Task.isCancelled {
                    let message = try await candidate.receiveStreamMessage()
                    guard isCurrentConnection(generation, profileID: profile.id) else {
                        await candidate.disconnect()
                        return
                    }
                    try await consume(
                        message,
                        client: candidate,
                        generation: generation,
                        profileID: profile.id
                    )
                }
                await candidate.disconnect()
                return
            } catch is CancellationError {
                await client?.disconnect()
                return
            } catch {
                await client?.disconnect()
                guard isCurrentConnection(generation, profileID: profile.id), !Task.isCancelled else { return }
                activeClient = nil
                activeSessionToken = nil
                attempt += 1
                phase = attempt == 1
                    ? .failed(message: error.localizedDescription)
                    : .reconnecting(attempt: attempt)
                let delay = min(30.0, pow(2.0, Double(min(attempt, 5))))
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }
            }
        }
    }

    private func consume(
        _ message: StreamServerMessage,
        client: any BridgeConnecting,
        generation: Int,
        profileID: String
    ) async throws {
        guard isCurrentConnection(generation, profileID: profileID) else { return }
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
        case let .workspaceDirectory(document):
            let location = WorkspaceFileLocation(
                workspaceID: document.workspaceID,
                relativePath: document.relativePath
            )
            guard workspaceDirectoryRequestIDs[location] == document.requestID,
                  document.sessionID == activeSessionID else { return }
            workspaceDirectoryLoadingLocations.remove(location)
            workspaceDirectoryRequestIDs[location] = nil
            workspaceDirectories[location] = document
        case let .workspaceFile(document):
            let location = WorkspaceFileLocation(
                workspaceID: document.workspaceID,
                relativePath: document.relativePath
            )
            guard workspaceFileRequestIDs[location] == document.requestID,
                  document.sessionID == activeSessionID else { return }
            workspaceFileLoadingLocations.remove(location)
            workspaceFileSavingLocations.remove(location)
            workspaceFileRequestIDs[location] = nil
            workspaceFiles[location] = document
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
        workspaceDirectories = [:]
        workspaceFiles = [:]
        workspaceDirectoryLoadingLocations = []
        workspaceFileLoadingLocations = []
        workspaceFileSavingLocations = []
        workspaceDirectoryRequestIDs = [:]
        workspaceFileRequestIDs = [:]
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
        if let selectedProfileID,
           let index = profiles.firstIndex(where: { $0.id == selectedProfileID }) {
            profiles[index].displayName = newSnapshot.instance.name
            profiles[index].bridgeInstanceID = newSnapshot.instance.id
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
        let generation = connectionGeneration
        Task {
            do {
                try await client.sendStreamMessage(.configureNotifications(request))
            } catch {
                guard generation == connectionGeneration, notificationRequestID == requestID else { return }
                notificationRequestID = nil
                notificationErrorMessage = "Notification settings could not reach the host."
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
            toast = ToastMessage(text: "The host is not connected.", isError: true)
            return
        }
        let generation = connectionGeneration
        Task {
            do {
                try await client.sendStreamMessage(.action(action))
            } catch {
                guard generation == connectionGeneration else { return }
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
