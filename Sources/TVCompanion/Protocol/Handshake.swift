import CryptoKit
import Foundation

/// How a client authenticates a handshake.
enum HandshakeMode: String, Codable, Sendable {
    /// First pairing, confirmed by the user typing the code shown on the host.
    case pairCode
    /// First pairing, authenticated by a secret the host shared out of band (QR code).
    case pairSecret
    /// Reconnection of a paired device, authenticated by stored identity keys.
    case resume
}

// MARK: - Handshake messages (sent in the clear)

struct ClientHello: Codable, Sendable {
    var version: Int
    var mode: HandshakeMode
    var clientName: String
    /// The client's identity, for `resume`.
    var clientID: String?
    /// SHA-256 of the client's ephemeral key and nonce, sent before seeing
    /// the host's key so neither side can choose keys to force a code.
    var commitment: Data
}

struct HostHello: Codable, Sendable {
    var version: Int
    var hostName: String
    var hostID: String
    var ephemeralKey: Data
    var nonce: Data
}

struct ClientReveal: Codable, Sendable {
    var ephemeralKey: Data
    var nonce: Data
}

/// A handshake failure the host reports before closing.
struct HandshakeRejection: Codable, Sendable {
    var reason: String
}

// MARK: - Messages sent over the encrypted channel during setup

struct ConfirmMessage: Codable, Sendable {
    var mac: Data
}

struct IdentityMessage: Codable, Sendable {
    var name: String
    var publicKey: Data
}

struct AuthMessage: Codable, Sendable {
    var signature: Data
}

// MARK: - Crypto

/// The pieces of the handshake protocol, free of networking so they can be
/// tested (and reasoned about) directly.
///
/// ```
/// client                                   host
///   ClientHello(mode, commitment) ───────▶
///                          ◀─────── HostHello(eH, nH, hostID)
///   ClientReveal(eC, nC) ────────────────▶  (host checks the commitment)
///   both: shared = X25519(eC, eH); T = SHA-256(transcript)
///         keys = HKDF(shared [+ secret], salt: T)
/// pairCode:   host shows code = HKDF(shared, T, "code") mod 10⁶;
///             user types it on the client, which compares with its own
/// pairSecret: the secret from the QR code is mixed into the keys
///   Confirm(MAC_client) ═════════════════▶  (encrypted; host verifies)
///                          ◀═════════ Confirm(MAC_host)
///   Identity(name, Ed25519 key) ⇄ Identity(name, Ed25519 key)
/// resume:     each side signs T with its stored identity key instead
/// ```
///
/// Against an active attacker the code check fails unless the attacker's
/// two sessions happen to produce the same code: one chance in a million
/// per pairing attempt, because the commitment stops them from choosing
/// keys after seeing the client's.
enum Handshake {
    static let version = 1
    static let nonceSize = 32

    /// A fresh X25519 key and nonce for one handshake.
    struct Ephemeral: Sendable {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let nonce: Data = randomBytes(Handshake.nonceSize)

        var publicKey: Data { privateKey.publicKey.rawRepresentation }

        var commitment: Data { Handshake.commitment(publicKey: publicKey, nonce: nonce) }
    }

    static func commitment(publicKey: Data, nonce: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data("TVCompanion commitment".utf8))
        hasher.update(data: publicKey)
        hasher.update(data: nonce)
        return Data(hasher.finalize())
    }

    /// Checks a reveal against the earlier commitment, in constant time.
    static func verifyCommitment(_ commitment: Data, reveal: ClientReveal) -> Bool {
        let expected = Self.commitment(publicKey: reveal.ephemeralKey, nonce: reveal.nonce)
        return constantTimeEqual(expected, commitment) && reveal.nonce.count == nonceSize
    }

    /// Derives the session keys from the key agreement and transcript.
    static func deriveKeys(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Data,
        transcript: Data,
        secret: SymmetricKey?
    ) throws -> SessionKeys {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let sharedKey = shared.withUnsafeBytes { SymmetricKey(data: Data($0)) }
        // All-zero shared secrets come from low-order public keys.
        guard sharedKey.withUnsafeBytes({ $0.contains { $0 != 0 } }) else { throw CompanionError.handshakeFailed("invalid key") }

        var material = sharedKey.withUnsafeBytes { Data($0) }
        if let secret { material.append(secret.withUnsafeBytes { Data($0) }) }
        let keyMaterial = SymmetricKey(data: material)

        func derive(_ label: String, from key: SymmetricKey = keyMaterial) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: transcript, info: Data("TVCompanion v1 \(label)".utf8), outputByteCount: 32)
        }
        // The code only depends on the key agreement, so both sides of an
        // honest code pairing compute the same one.
        let codeKey = derive("code", from: sharedKey)
        let codeValue = codeKey.withUnsafeBytes { bytes in
            bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
        return SessionKeys(
            clientToHost: derive("client to host"),
            hostToClient: derive("host to client"),
            confirmation: derive("confirmation"),
            pairingCode: String(format: "%06u", codeValue % 1_000_000),
            transcript: transcript
        )
    }

    enum Role: String, Sendable {
        case client
        case host
    }

    /// Proves knowledge of the session keys (and, in secret mode, the secret).
    static func confirmationMAC(_ keys: SessionKeys, role: Role) -> Data {
        var mac = HMAC<SHA256>(key: keys.confirmation)
        mac.update(data: Data("TVCompanion confirm \(role.rawValue)".utf8))
        mac.update(data: keys.transcript)
        return Data(mac.finalize())
    }

    static func verifyConfirmation(_ data: Data, keys: SessionKeys, role: Role) -> Bool {
        constantTimeEqual(data, confirmationMAC(keys, role: role))
    }

    /// The bytes a device signs to authenticate a `resume` handshake.
    static func signedData(_ keys: SessionKeys, role: Role) -> Data {
        Data("TVCompanion resume \(role.rawValue)".utf8) + keys.transcript
    }
}

/// Keys and values derived from one handshake.
struct SessionKeys: Sendable {
    let clientToHost: SymmetricKey
    let hostToClient: SymmetricKey
    let confirmation: SymmetricKey
    /// The six-digit code shown by the host during code pairing.
    let pairingCode: String
    let transcript: Data
}

/// Accumulates the handshake transcript.
struct Transcript: Sendable {
    private var hasher = SHA256()

    init(mode: HandshakeMode) {
        hasher.update(data: Data("TVCompanion v\(Handshake.version) \(mode.rawValue)".utf8))
    }

    /// Adds a message, length-prefixed so boundaries are unambiguous.
    mutating func append(_ data: Data) {
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data)
    }

    var digest: Data { Data(hasher.finalize()) }
}

func randomBytes(_ count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
}

func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
    return difference == 0
}

/// Codable helpers for the wire format.
enum Wire {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dataEncodingStrategy = .base64
        return encoder
    }()

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CompanionError.protocolViolation("malformed \(type)")
        }
    }
}
