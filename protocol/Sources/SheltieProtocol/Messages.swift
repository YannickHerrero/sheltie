import Foundation

public struct HealthResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let bridgeVersion: String
    public let protocolVersion: Int
    public let herdrReachable: Bool

    public init(ok: Bool, bridgeVersion: String, protocolVersion: Int, herdrReachable: Bool) {
        self.ok = ok
        self.bridgeVersion = bridgeVersion
        self.protocolVersion = protocolVersion
        self.herdrReachable = herdrReachable
    }
}

public struct TerminalSubscription: Codable, Equatable, Sendable {
    public let sessionID: String
    public let paneID: String
    public let columns: Int
    public let rows: Int
    public let writable: Bool

    public init(sessionID: String, paneID: String, columns: Int, rows: Int, writable: Bool) {
        self.sessionID = sessionID
        self.paneID = paneID
        self.columns = columns
        self.rows = rows
        self.writable = writable
    }
}

public struct TerminalFrame: Codable, Equatable, Sendable {
    public let sessionID: String
    public let paneID: String
    public let sequence: Int64
    public let full: Bool
    public let columns: Int
    public let rows: Int
    public let bytesBase64: String

    public init(
        sessionID: String,
        paneID: String,
        sequence: Int64,
        full: Bool,
        columns: Int,
        rows: Int,
        bytesBase64: String
    ) {
        self.sessionID = sessionID
        self.paneID = paneID
        self.sequence = sequence
        self.full = full
        self.columns = columns
        self.rows = rows
        self.bytesBase64 = bytesBase64
    }

    public var bytes: Data? { Data(base64Encoded: bytesBase64) }
}

public struct TerminalClosed: Codable, Equatable, Sendable {
    public let sessionID: String
    public let paneID: String
    public let reason: String

    public init(sessionID: String, paneID: String, reason: String) {
        self.sessionID = sessionID
        self.paneID = paneID
        self.reason = reason
    }
}

public enum ActionType: String, Codable, Sendable {
    case focusWorkspace = "workspace.focus"
    case createWorkspace = "workspace.create"
    case renameWorkspace = "workspace.rename"
    case closeWorkspace = "workspace.close"
    case focusTab = "tab.focus"
    case createTab = "tab.create"
    case renameTab = "tab.rename"
    case closeTab = "tab.close"
    case focusPane = "pane.focus"
    case splitPane = "pane.split"
    case movePane = "pane.move"
    case resizePane = "pane.resize"
    case setSplitRatio = "layout.set_split_ratio"
    case zoomPane = "pane.zoom"
    case renamePane = "pane.rename"
    case closePane = "pane.close"
    case terminalInput = "terminal.input"
    case terminalKeys = "terminal.keys"
    case terminalResize = "terminal.resize"
    case agentMessage = "agent.message"
}

public enum PaneMoveDestination: Codable, Equatable, Sendable {
    case tab(tabID: String, targetPaneID: String?, split: SplitDirection)
    case newTab(workspaceID: String?, label: String?)
    case newWorkspace(label: String?, tabLabel: String?)

    private enum CodingKeys: String, CodingKey {
        case type, tabID, targetPaneID, split, workspaceID, label, tabLabel
    }

    private enum DestinationType: String, Codable {
        case tab
        case newTab = "new_tab"
        case newWorkspace = "new_workspace"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(DestinationType.self, forKey: .type) {
        case .tab:
            self = .tab(
                tabID: try container.decode(String.self, forKey: .tabID),
                targetPaneID: try container.decodeIfPresent(String.self, forKey: .targetPaneID),
                split: try container.decode(SplitDirection.self, forKey: .split)
            )
        case .newTab:
            self = .newTab(
                workspaceID: try container.decodeIfPresent(String.self, forKey: .workspaceID),
                label: try container.decodeIfPresent(String.self, forKey: .label)
            )
        case .newWorkspace:
            self = .newWorkspace(
                label: try container.decodeIfPresent(String.self, forKey: .label),
                tabLabel: try container.decodeIfPresent(String.self, forKey: .tabLabel)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .tab(tabID, targetPaneID, split):
            try container.encode(DestinationType.tab, forKey: .type)
            try container.encode(tabID, forKey: .tabID)
            try container.encodeIfPresent(targetPaneID, forKey: .targetPaneID)
            try container.encode(split, forKey: .split)
        case let .newTab(workspaceID, label):
            try container.encode(DestinationType.newTab, forKey: .type)
            try container.encodeIfPresent(workspaceID, forKey: .workspaceID)
            try container.encodeIfPresent(label, forKey: .label)
        case let .newWorkspace(label, tabLabel):
            try container.encode(DestinationType.newWorkspace, forKey: .type)
            try container.encodeIfPresent(label, forKey: .label)
            try container.encodeIfPresent(tabLabel, forKey: .tabLabel)
        }
    }
}

public struct ActionCommand: Codable, Equatable, Sendable {
    public let requestID: String
    public let sessionID: String
    public let type: ActionType
    public let targetID: String?
    public let text: String?
    public let bytesBase64: String?
    public let keys: [String]?
    public let splitDirection: SplitDirection?
    public let paneDirection: PaneDirection?
    public let ratio: Double?
    public let splitPath: [Bool]?
    public let moveDestination: PaneMoveDestination?
    public let label: String?
    public let cwd: String?
    public let columns: Int?
    public let rows: Int?

    public init(
        requestID: String = UUID().uuidString,
        sessionID: String,
        type: ActionType,
        targetID: String? = nil,
        text: String? = nil,
        bytesBase64: String? = nil,
        keys: [String]? = nil,
        splitDirection: SplitDirection? = nil,
        paneDirection: PaneDirection? = nil,
        ratio: Double? = nil,
        splitPath: [Bool]? = nil,
        moveDestination: PaneMoveDestination? = nil,
        label: String? = nil,
        cwd: String? = nil,
        columns: Int? = nil,
        rows: Int? = nil
    ) {
        self.requestID = requestID
        self.sessionID = sessionID
        self.type = type
        self.targetID = targetID
        self.text = text
        self.bytesBase64 = bytesBase64
        self.keys = keys
        self.splitDirection = splitDirection
        self.paneDirection = paneDirection
        self.ratio = ratio
        self.splitPath = splitPath
        self.moveDestination = moveDestination
        self.label = label
        self.cwd = cwd
        self.columns = columns
        self.rows = rows
    }
}

public struct ActionResult: Codable, Equatable, Sendable {
    public let requestID: String
    public let ok: Bool
    public let errorCode: String?
    public let message: String?

    public init(requestID: String, ok: Bool, errorCode: String? = nil, message: String? = nil) {
        self.requestID = requestID
        self.ok = ok
        self.errorCode = errorCode
        self.message = message
    }
}

public struct PairStartRequest: Codable, Equatable, Sendable {
    public let deviceName: String
    public let publicKeyDERBase64: String

    public init(deviceName: String, publicKeyDERBase64: String) {
        self.deviceName = deviceName
        self.publicKeyDERBase64 = publicKeyDERBase64
    }
}

public struct PairStartResponse: Codable, Equatable, Sendable {
    public let pairingID: String
    public let challengeBase64: String
    public let expiresAtMillis: Int64

    public init(pairingID: String, challengeBase64: String, expiresAtMillis: Int64) {
        self.pairingID = pairingID
        self.challengeBase64 = challengeBase64
        self.expiresAtMillis = expiresAtMillis
    }
}

public struct PairCompleteRequest: Codable, Equatable, Sendable {
    public let pairingID: String
    public let code: String
    public let signatureDERBase64: String

    public init(pairingID: String, code: String, signatureDERBase64: String) {
        self.pairingID = pairingID
        self.code = code
        self.signatureDERBase64 = signatureDERBase64
    }
}

public struct PairCompleteResponse: Codable, Equatable, Sendable {
    public let deviceID: String
    public let accessToken: String
    public let instance: InstanceInfo

    public init(deviceID: String, accessToken: String, instance: InstanceInfo) {
        self.deviceID = deviceID
        self.accessToken = accessToken
        self.instance = instance
    }
}

public enum StreamServerMessage: Codable, Equatable, Sendable {
    case snapshot(BootstrapSnapshot)
    case terminalFrame(TerminalFrame)
    case terminalClosed(TerminalClosed)
    case actionResult(ActionResult)
    case sessionExpiring(expiresAtMillis: Int64)
    case ping(id: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case snapshot
        case frame
        case terminal
        case result
        case expiresAtMillis
        case id
    }

    private enum MessageType: String, Codable {
        case snapshot
        case terminalFrame = "terminal.frame"
        case terminalClosed = "terminal.closed"
        case actionResult = "action.result"
        case sessionExpiring = "session.expiring"
        case ping
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(MessageType.self, forKey: .type) {
        case .snapshot:
            self = .snapshot(try container.decode(BootstrapSnapshot.self, forKey: .snapshot))
        case .terminalFrame:
            self = .terminalFrame(try container.decode(TerminalFrame.self, forKey: .frame))
        case .terminalClosed:
            self = .terminalClosed(try container.decode(TerminalClosed.self, forKey: .terminal))
        case .actionResult:
            self = .actionResult(try container.decode(ActionResult.self, forKey: .result))
        case .sessionExpiring:
            self = .sessionExpiring(expiresAtMillis: try container.decode(Int64.self, forKey: .expiresAtMillis))
        case .ping:
            self = .ping(id: try container.decode(String.self, forKey: .id))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .snapshot(snapshot):
            try container.encode(MessageType.snapshot, forKey: .type)
            try container.encode(snapshot, forKey: .snapshot)
        case let .terminalFrame(frame):
            try container.encode(MessageType.terminalFrame, forKey: .type)
            try container.encode(frame, forKey: .frame)
        case let .terminalClosed(terminal):
            try container.encode(MessageType.terminalClosed, forKey: .type)
            try container.encode(terminal, forKey: .terminal)
        case let .actionResult(result):
            try container.encode(MessageType.actionResult, forKey: .type)
            try container.encode(result, forKey: .result)
        case let .sessionExpiring(expiresAtMillis):
            try container.encode(MessageType.sessionExpiring, forKey: .type)
            try container.encode(expiresAtMillis, forKey: .expiresAtMillis)
        case let .ping(id):
            try container.encode(MessageType.ping, forKey: .type)
            try container.encode(id, forKey: .id)
        }
    }
}

public enum StreamClientMessage: Codable, Equatable, Sendable {
    case subscribe([TerminalSubscription])
    case action(ActionCommand)
    case resync
    case pong(id: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case subscriptions
        case action
        case id
    }

    private enum MessageType: String, Codable {
        case subscribe
        case action
        case resync
        case pong
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(MessageType.self, forKey: .type) {
        case .subscribe:
            self = .subscribe(try container.decode([TerminalSubscription].self, forKey: .subscriptions))
        case .action:
            self = .action(try container.decode(ActionCommand.self, forKey: .action))
        case .resync:
            self = .resync
        case .pong:
            self = .pong(id: try container.decode(String.self, forKey: .id))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .subscribe(subscriptions):
            try container.encode(MessageType.subscribe, forKey: .type)
            try container.encode(subscriptions, forKey: .subscriptions)
        case let .action(action):
            try container.encode(MessageType.action, forKey: .type)
            try container.encode(action, forKey: .action)
        case .resync:
            try container.encode(MessageType.resync, forKey: .type)
        case let .pong(id):
            try container.encode(MessageType.pong, forKey: .type)
            try container.encode(id, forKey: .id)
        }
    }
}
