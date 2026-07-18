import CryptoKit
import Foundation
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

@MainActor
@Test func demoStoreBootstrapsSelectionAndTerminalFrames() {
    let store = AppStore(repository: MemoryInstanceRepository(), arguments: ["tests", "--demo"])

    #expect(store.phase == .connected)
    #expect(store.selectedWorkspaceID == "w1")
    #expect(store.selectedTabID == "w1:t1")
    #expect(store.selectedPaneID == "w1:p1")
    #expect(store.terminalFrames["w1:p1"]?.full == true)
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
