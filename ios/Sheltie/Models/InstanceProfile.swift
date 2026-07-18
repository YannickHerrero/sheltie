import Foundation

struct InstanceProfile: Codable, Equatable, Hashable, Identifiable {
    let id: String
    var displayName: String
    var baseURL: URL
    var deviceID: String
    var lastConnectedAt: Date?

    init(
        id: String,
        displayName: String,
        baseURL: URL,
        deviceID: String,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.deviceID = deviceID
        self.lastConnectedAt = lastConnectedAt
    }
}

struct PendingPairing: Equatable {
    let baseURL: URL
    let pairingID: String
    let challenge: Data
    let expiresAt: Date
}

enum ConnectionPhase: Equatable {
    case noInstances
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(message: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

struct ToastMessage: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let isError: Bool
}

struct TerminalViewport: Equatable {
    let columns: Int
    let rows: Int

    static let fallback = TerminalViewport(columns: 100, rows: 36)
}
