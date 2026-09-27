import CryptoKit
import Foundation

/// Encrypts and authenticates messages in each direction with
/// ChaCha20-Poly1305.
///
/// Nonces are message counters, so each key never reuses a nonce, and a
/// dropped, replayed, reordered or modified message fails to open.
struct SecureChannel: Sendable {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    init(keys: SessionKeys, role: Handshake.Role) {
        switch role {
        case .client:
            sendKey = keys.clientToHost
            receiveKey = keys.hostToClient
        case .host:
            sendKey = keys.hostToClient
            receiveKey = keys.clientToHost
        }
    }

    mutating func seal(_ plaintext: Data) throws -> Data {
        guard sendCounter < .max else { throw CompanionError.connectionClosed }
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: Self.nonce(sendCounter))
        sendCounter += 1
        return box.ciphertext + box.tag
    }

    mutating func open(_ data: Data) throws -> Data {
        guard data.count >= 16, receiveCounter < .max else { throw CompanionError.protocolViolation("message too short") }
        let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(receiveCounter), ciphertext: data.dropLast(16), tag: data.suffix(16))
        do {
            let plaintext = try ChaChaPoly.open(box, using: receiveKey)
            receiveCounter += 1
            return plaintext
        } catch {
            throw CompanionError.protocolViolation("message failed authentication")
        }
    }

    static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes) // 12 bytes, always valid
    }
}

/// Splits a byte stream into length-prefixed frames.
struct FrameDecoder: Sendable {
    static let maximumFrameSize = 1 << 20

    private var buffer = Data()

    /// Appends bytes and returns every complete frame.
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length <= Self.maximumFrameSize else { throw CompanionError.protocolViolation("frame too large") }
            guard buffer.count >= 4 + length else { break }
            frames.append(Data(buffer.dropFirst(4).prefix(length)))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return frames
    }

    static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        return Data(bytes: &length, count: 4) + payload
    }
}
