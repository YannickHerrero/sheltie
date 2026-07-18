import Foundation

protocol InstancePersisting {
    func loadProfiles() -> [InstanceProfile]
    func saveProfiles(_ profiles: [InstanceProfile])
    func loadSelectedID() -> String?
    func saveSelectedID(_ id: String?)
    func accessToken(for instanceID: String) throws -> String?
    func setAccessToken(_ token: String, for instanceID: String) throws
    func removeAccessToken(for instanceID: String) throws
}

struct InstanceRepository: InstancePersisting {
    private let defaults: UserDefaults
    private let keychain: KeychainStore
    private let profilesKey = "instance-profiles-v1"
    private let selectedKey = "selected-instance-v1"

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
    }

    func loadProfiles() -> [InstanceProfile] {
        guard let data = defaults.data(forKey: profilesKey) else { return [] }
        return (try? JSONDecoder().decode([InstanceProfile].self, from: data)) ?? []
    }

    func saveProfiles(_ profiles: [InstanceProfile]) {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: profilesKey)
        }
    }

    func loadSelectedID() -> String? {
        defaults.string(forKey: selectedKey)
    }

    func saveSelectedID(_ id: String?) {
        defaults.set(id, forKey: selectedKey)
    }

    func accessToken(for instanceID: String) throws -> String? {
        guard let data = try keychain.data(for: tokenAccount(instanceID)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setAccessToken(_ token: String, for instanceID: String) throws {
        try keychain.set(Data(token.utf8), for: tokenAccount(instanceID))
    }

    func removeAccessToken(for instanceID: String) throws {
        try keychain.remove(tokenAccount(instanceID))
    }

    private func tokenAccount(_ instanceID: String) -> String {
        "instance.\(instanceID).access-token"
    }
}
