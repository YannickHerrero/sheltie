import Foundation
import SheltieProtocol
import Testing
@testable import Sheltie

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct BridgeClientTests {
    @Test func preservesTailscaleServeBasePath() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = BridgeClient(baseURL: URL(string: "https://studio.example.ts.net/sheltie")!, session: session)

        StubURLProtocol.handler = { request in
            #expect(request.url?.path == "/sheltie/v1/pair/start")
            #expect(request.httpMethod == "POST")
            let response = PairStartResponse(pairingID: "pair-1", challengeBase64: Data("challenge".utf8).base64EncodedString(), expiresAtMillis: 123)
            let data = try JSONEncoder().encode(response)
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, data)
        }

        let response = try await client.startPairing(deviceName: "iPad", publicKeyDER: Data([1, 2, 3]))
        #expect(response.pairingID == "pair-1")
    }

    @Test func surfacesServerPairingErrors() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = BridgeClient(
            baseURL: URL(string: "https://studio.example.ts.net/sheltie")!,
            session: URLSession(configuration: configuration)
        )
        StubURLProtocol.handler = { request in
            let data = Data("{\"error\":\"invalid_pairing\",\"message\":\"Pairing code is incorrect\"}".utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, data)
        }

        await #expect(throws: BridgeClientError.self) {
            try await client.completePairing(pairingID: "pair-1", code: "000000", signature: Data([1]))
        }
    }
}
