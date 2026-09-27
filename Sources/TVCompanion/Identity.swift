import CryptoKit
import Foundation
import Security

/// This device's long-term identity: an Ed25519 key pair.
public struct CompanionIdentity: Sendable {
    let signingKey: Curve25519.Signing.PrivateKey

    public init() {
        signingKey = Curve25519.Signing.PrivateKey()
    }

    init(rawRepresentation: Data) throws {
        signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    }

    var rawRepresentation: Data { signingKey.rawRepresentation }

    public var publicKey: Data { signingKey.publicKey.rawRepresentation }

    /// A short, stable identifier derived from the public key.
    public var id: String { Self.id(for: publicKey) }

    static func id(for publicKey: Data) -> String {
        SHA256.hash(data: publicKey).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func sign(_ data: Data) throws -> Data {
        try signingKey.signature(for: data)
    }
}

/// A device paired with this one.
public struct PairedDevice: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public var name: String
    public let publicKey: Data
    public let pairedAt: Date

    public init(name: String, publicKey: Data, pairedAt: Date = Date()) {
        self.id = CompanionIdentity.id(for: publicKey)
        self.name = name
        self.publicKey = publicKey
        self.pairedAt = pairedAt
    }

    func verify(_ signature: Data, for data: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: data)
    }
}

/// Persists this device's identity and its paired devices.
public protocol PairingStore: Sendable {
    func identity() throws -> CompanionIdentity
    func pairedDevices() throws -> [PairedDevice]
    func save(_ device: PairedDevice) throws
    func removeDevice(id: String) throws
}

/// Keeps pairings in memory. For tests and previews.
public final class InMemoryPairingStore: PairingStore, @unchecked Sendable {
    private let lock = NSLock()
    private let ownIdentity = CompanionIdentity()
    private var devices: [String: PairedDevice] = [:]

    public init() {}

    public func identity() throws -> CompanionIdentity { ownIdentity }

    public func pairedDevices() throws -> [PairedDevice] {
        lock.withLock { devices.values.sorted { $0.pairedAt < $1.pairedAt } }
    }

    public func save(_ device: PairedDevice) throws {
        lock.withLock { devices[device.id] = device }
    }

    public func removeDevice(id: String) throws {
        lock.withLock { _ = devices.removeValue(forKey: id) }
    }
}

/// Keeps the identity key and pairings in the keychain (device-only, readable
/// after first unlock so background reconnections work).
public final class KeychainPairingStore: PairingStore, @unchecked Sendable {
    public let service: String
    public let accessGroup: String?
    private let lock = NSLock()

    public init(service: String = "TVCompanion", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func identity() throws -> CompanionIdentity {
        try lock.withLock {
            if let data = try read("identity") {
                return try CompanionIdentity(rawRepresentation: data)
            }
            let identity = CompanionIdentity()
            try write("identity", identity.rawRepresentation)
            return identity
        }
    }

    public func pairedDevices() throws -> [PairedDevice] {
        try lock.withLock { try loadDevices() }
    }

    public func save(_ device: PairedDevice) throws {
        try lock.withLock {
            var devices = try loadDevices().filter { $0.id != device.id }
            devices.append(device)
            try write("devices", JSONEncoder().encode(devices))
        }
    }

    public func removeDevice(id: String) throws {
        try lock.withLock {
            let devices = try loadDevices().filter { $0.id != id }
            try write("devices", JSONEncoder().encode(devices))
        }
    }

    private func loadDevices() throws -> [PairedDevice] {
        guard let data = try read("devices") else { return [] }
        return (try? JSONDecoder().decode([PairedDevice].self, from: data)) ?? []
    }

    private func query(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    private func read(_ account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CompanionError.handshakeFailed("keychain error \(status)") }
        return result as? Data
    }

    private func write(_ account: String, _ data: Data) throws {
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        var item = query(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw CompanionError.handshakeFailed("keychain error \(status)") }
    }
}
