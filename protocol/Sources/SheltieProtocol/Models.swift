import Foundation

public enum SheltieProtocolVersion {
    public static let current = 1
}

public enum AgentStatus: String, Codable, CaseIterable, Sendable {
    case idle
    case working
    case blocked
    case done
    case unknown
}

public enum PaneKind: String, Codable, Sendable {
    case agent
    case shell
}

public enum SplitDirection: String, Codable, Sendable {
    case horizontal
    case vertical
}

public enum PaneDirection: String, Codable, Sendable {
    case left
    case right
    case up
    case down
}

public struct BridgeInfo: Codable, Equatable, Sendable {
    public let version: String
    public let protocolVersion: Int
    public let capabilities: [String]

    public init(version: String, protocolVersion: Int, capabilities: [String]) {
        self.version = version
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
    }
}

public struct InstanceInfo: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let host: String

    public init(id: String, name: String, host: String) {
        self.id = id
        self.name = name
        self.host = host
    }
}

public struct HerdrInfo: Codable, Equatable, Sendable {
    public let version: String
    public let protocolVersion: Int
    public let capabilities: [String]

    public init(version: String, protocolVersion: Int, capabilities: [String]) {
        self.version = version
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
    }
}

public struct SessionSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let isDefault: Bool
    public let reachable: Bool

    public init(id: String, name: String, isDefault: Bool, reachable: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.reachable = reachable
    }
}

public struct WorkspaceSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let number: Int
    public let label: String
    public let path: String?
    public let branch: String?
    public let activeTabID: String?
    public let paneCount: Int
    public let tabCount: Int
    public let status: AgentStatus
    public let focused: Bool

    public init(
        id: String,
        number: Int,
        label: String,
        path: String? = nil,
        branch: String? = nil,
        activeTabID: String? = nil,
        paneCount: Int,
        tabCount: Int,
        status: AgentStatus,
        focused: Bool
    ) {
        self.id = id
        self.number = number
        self.label = label
        self.path = path
        self.branch = branch
        self.activeTabID = activeTabID
        self.paneCount = paneCount
        self.tabCount = tabCount
        self.status = status
        self.focused = focused
    }
}

public struct TabSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let workspaceID: String
    public let number: Int
    public let label: String
    public let paneCount: Int
    public let status: AgentStatus
    public let focused: Bool

    public init(
        id: String,
        workspaceID: String,
        number: Int,
        label: String,
        paneCount: Int,
        status: AgentStatus,
        focused: Bool
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.number = number
        self.label = label
        self.paneCount = paneCount
        self.status = status
        self.focused = focused
    }
}

public struct PaneSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let terminalID: String
    public let workspaceID: String
    public let tabID: String
    public let title: String
    public let cwd: String
    public let kind: PaneKind
    public let agentName: String?
    public let agentDisplayName: String?
    public let agentStatus: AgentStatus
    public let focused: Bool
    public let revision: Int64

    public init(
        id: String,
        terminalID: String,
        workspaceID: String,
        tabID: String,
        title: String,
        cwd: String,
        kind: PaneKind,
        agentName: String? = nil,
        agentDisplayName: String? = nil,
        agentStatus: AgentStatus,
        focused: Bool,
        revision: Int64
    ) {
        self.id = id
        self.terminalID = terminalID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.title = title
        self.cwd = cwd
        self.kind = kind
        self.agentName = agentName
        self.agentDisplayName = agentDisplayName
        self.agentStatus = agentStatus
        self.focused = focused
        self.revision = revision
    }
}

public struct AgentSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let paneID: String
    public let workspaceID: String
    public let tabID: String
    public let name: String
    public let displayName: String
    public let status: AgentStatus
    public let statusLabel: String?

    public init(
        id: String,
        paneID: String,
        workspaceID: String,
        tabID: String,
        name: String,
        displayName: String,
        status: AgentStatus,
        statusLabel: String? = nil
    ) {
        self.id = id
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.name = name
        self.displayName = displayName
        self.status = status
        self.statusLabel = statusLabel
    }
}

public indirect enum LayoutNode: Codable, Equatable, Sendable {
    case pane(paneID: String)
    case split(direction: SplitDirection, ratio: Double, first: LayoutNode, second: LayoutNode)

    private enum CodingKeys: String, CodingKey {
        case type
        case paneID
        case direction
        case ratio
        case first
        case second
    }

    private enum NodeType: String, Codable {
        case pane
        case split
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(NodeType.self, forKey: .type) {
        case .pane:
            self = .pane(paneID: try container.decode(String.self, forKey: .paneID))
        case .split:
            self = .split(
                direction: try container.decode(SplitDirection.self, forKey: .direction),
                ratio: try container.decode(Double.self, forKey: .ratio),
                first: try container.decode(LayoutNode.self, forKey: .first),
                second: try container.decode(LayoutNode.self, forKey: .second)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .pane(paneID):
            try container.encode(NodeType.pane, forKey: .type)
            try container.encode(paneID, forKey: .paneID)
        case let .split(direction, ratio, first, second):
            try container.encode(NodeType.split, forKey: .type)
            try container.encode(direction, forKey: .direction)
            try container.encode(ratio, forKey: .ratio)
            try container.encode(first, forKey: .first)
            try container.encode(second, forKey: .second)
        }
    }
}

public struct PaneLayoutSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: String { tabID }

    public let workspaceID: String
    public let tabID: String
    public let zoomed: Bool
    public let focusedPaneID: String?
    public let root: LayoutNode

    public init(
        workspaceID: String,
        tabID: String,
        zoomed: Bool,
        focusedPaneID: String? = nil,
        root: LayoutNode
    ) {
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.zoomed = zoomed
        self.focusedPaneID = focusedPaneID
        self.root = root
    }
}

public struct FocusSnapshot: Codable, Equatable, Sendable {
    public let workspaceID: String?
    public let tabID: String?
    public let paneID: String?

    public init(workspaceID: String?, tabID: String?, paneID: String?) {
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.paneID = paneID
    }
}

public struct UsageMeter: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let provider: String
    public let label: String
    public let remainingFraction: Double
    public let resetAtMillis: Int64?
    public let observedAtMillis: Int64

    public init(
        id: String,
        provider: String,
        label: String,
        remainingFraction: Double,
        resetAtMillis: Int64? = nil,
        observedAtMillis: Int64
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.remainingFraction = remainingFraction
        self.resetAtMillis = resetAtMillis
        self.observedAtMillis = observedAtMillis
    }
}

public struct BootstrapSnapshot: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let bridge: BridgeInfo
    public let instance: InstanceInfo
    public let herdr: HerdrInfo
    public let sessions: [SessionSummary]
    public let activeSessionID: String?
    public let workspaces: [WorkspaceSnapshot]
    public let tabs: [TabSnapshot]
    public let panes: [PaneSnapshot]
    public let agents: [AgentSnapshot]
    public let layouts: [PaneLayoutSnapshot]
    public let focus: FocusSnapshot
    public let usageMeters: [UsageMeter]
    public let generatedAtMillis: Int64

    public init(
        protocolVersion: Int = SheltieProtocolVersion.current,
        bridge: BridgeInfo,
        instance: InstanceInfo,
        herdr: HerdrInfo,
        sessions: [SessionSummary],
        activeSessionID: String?,
        workspaces: [WorkspaceSnapshot],
        tabs: [TabSnapshot],
        panes: [PaneSnapshot],
        agents: [AgentSnapshot],
        layouts: [PaneLayoutSnapshot],
        focus: FocusSnapshot,
        usageMeters: [UsageMeter] = [],
        generatedAtMillis: Int64
    ) {
        self.protocolVersion = protocolVersion
        self.bridge = bridge
        self.instance = instance
        self.herdr = herdr
        self.sessions = sessions
        self.activeSessionID = activeSessionID
        self.workspaces = workspaces
        self.tabs = tabs
        self.panes = panes
        self.agents = agents
        self.layouts = layouts
        self.focus = focus
        self.usageMeters = usageMeters
        self.generatedAtMillis = generatedAtMillis
    }
}
