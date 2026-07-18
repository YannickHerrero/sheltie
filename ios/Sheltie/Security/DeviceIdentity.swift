import CryptoKit
import Foundation
import Security

struct DeviceIdentity {
    private enum Backing {
        case secureEnclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)
    }

    private static let account = "device-signing-key-v1"
    private let backing: Backing

    var publicKeyDER: Data {
        switch backing {
        case let .secureEnclave(key): key.publicKey.derRepresentation
        case let .software(key): key.publicKey.derRepresentation
        }
    }

    func signature(for challenge: Data) throws -> Data {
        switch backing {
        case let .secureEnclave(key): try key.signature(for: challenge).derRepresentation
        case let .software(key): try key.signature(for: challenge).derRepresentation
        }
    }

    static func loadOrCreate(keychain: KeychainStore = KeychainStore()) throws -> DeviceIdentity {
        if let stored = try keychain.data(for: account), let kind = stored.first {
            let keyData = stored.dropFirst()
            if kind == 1, SecureEnclave.isAvailable {
                return DeviceIdentity(backing: .secureEnclave(
                    try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: Data(keyData))
                ))
            }
            if kind == 2 {
                return DeviceIdentity(backing: .software(
                    try P256.Signing.PrivateKey(rawRepresentation: keyData)
                ))
            }
        }

        if SecureEnclave.isAvailable {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                [.privateKeyUsage],
                &error
            ) else {
                throw error!.takeRetainedValue() as Error
            }
            let key = try SecureEnclave.P256.Signing.PrivateKey(
                compactRepresentable: false,
                accessControl: access
            )
            try keychain.set(Data([1]) + key.dataRepresentation, for: account)
            return DeviceIdentity(backing: .secureEnclave(key))
        }

        let key = P256.Signing.PrivateKey(compactRepresentable: false)
        try keychain.set(Data([2]) + key.rawRepresentation, for: account)
        return DeviceIdentity(backing: .software(key))
    }
}
