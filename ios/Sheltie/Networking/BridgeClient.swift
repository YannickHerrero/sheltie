import Foundation
import SheltieProtocol

struct SessionCredential: Decodable, Equatable {
    let sessionToken: String
    let deviceID: String
    let expiresAtMillis: Int64
}

enum BridgeClientError: Error, LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case server(status: Int, message: String)
    case unsupportedMessage

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: "The bridge URL is invalid."
        case .invalidResponse: "The bridge returned an invalid response."
        case let .server(_, message): message
        case .unsupportedMessage: "The bridge sent an unsupported WebSocket message."
        }
    }
}

actor BridgeClient {
    private struct ErrorEnvelope: Decodable {
        let error: String
        let message: String?
    }

    let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var webSocketTask: URLSessionWebSocketTask?

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    func startPairing(deviceName: String, publicKeyDER: Data) async throws -> PairStartResponse {
        try await post(
            "v1/pair/start",
            body: PairStartRequest(deviceName: deviceName, publicKeyDERBase64: publicKeyDER.base64EncodedString()),
            token: nil
        )
    }

    func completePairing(pairingID: String, code: String, signature: Data) async throws -> PairCompleteResponse {
        try await post(
            "v1/pair/complete",
            body: PairCompleteRequest(
                pairingID: pairingID,
                code: code,
                signatureDERBase64: signature.base64EncodedString()
            ),
            token: nil
        )
    }

    func refreshSession(accessToken: String) async throws -> SessionCredential {
        try await post("v1/session/refresh", body: EmptyBody(), token: accessToken)
    }

    func bootstrap(sessionID: String?, sessionToken: String) async throws -> BootstrapSnapshot {
        var components = URLComponents(url: try endpoint("v1/bootstrap"), resolvingAgainstBaseURL: false)
        if let sessionID {
            components?.queryItems = [URLQueryItem(name: "session", value: sessionID)]
        }
        guard let url = components?.url else { throw BridgeClientError.invalidBaseURL }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    func connectStream(sessionID: String, sessionToken: String) throws {
        var components = URLComponents(url: try endpoint("v1/stream"), resolvingAgainstBaseURL: false)
        let socketScheme = components?.scheme == "http" ? "ws" : "wss"
        components?.scheme = socketScheme
        components?.queryItems = [URLQueryItem(name: "session", value: sessionID)]
        guard let url = components?.url else { throw BridgeClientError.invalidBaseURL }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = task
        task.resume()
    }

    func receiveStreamMessage() async throws -> StreamServerMessage {
        guard let webSocketTask else { throw BridgeClientError.invalidResponse }
        let message = try await webSocketTask.receive()
        let data: Data
        switch message {
        case let .data(value): data = value
        case let .string(value): data = Data(value.utf8)
        @unknown default: throw BridgeClientError.unsupportedMessage
        }
        return try decoder.decode(StreamServerMessage.self, from: data)
    }

    func sendStreamMessage(_ message: StreamClientMessage) async throws {
        guard let webSocketTask else { throw BridgeClientError.invalidResponse }
        let data = try encoder.encode(message)
        try await webSocketTask.send(.data(data))
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    private func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        token: String?
    ) async throws -> Response {
        var request = URLRequest(url: try endpoint(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try encoder.encode(body)
        return try await send(request)
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BridgeClientError.invalidResponse }
        guard 200 ..< 300 ~= http.statusCode else {
            let envelope = try? decoder.decode(ErrorEnvelope.self, from: data)
            throw BridgeClientError.server(
                status: http.statusCode,
                message: envelope?.message ?? envelope?.error ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            )
        }
        return try decoder.decode(Response.self, from: data)
    }

    private func endpoint(_ path: String) throws -> URL {
        guard let scheme = baseURL.scheme?.lowercased(), scheme == "https" || scheme == "http",
              baseURL.host != nil else {
            throw BridgeClientError.invalidBaseURL
        }
        return path.split(separator: "/").reduce(baseURL) { partial, component in
            partial.appendingPathComponent(String(component), isDirectory: false)
        }
    }
}

private struct EmptyBody: Encodable {}
