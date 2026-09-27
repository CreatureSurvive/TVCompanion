import Foundation

/// An error from TVCompanion.
public enum CompanionError: Error, Sendable, Equatable, LocalizedError {
    /// The pairing code didn't match. The connection may have been
    /// intercepted, or the code was mistyped.
    case incorrectCode
    /// The host isn't accepting new pairings. Open its pairing screen.
    case pairingNotAvailable
    /// The device isn't paired (or was unpaired) and must pair again.
    case notPaired
    /// The handshake failed, for example because a key or signature was invalid.
    case handshakeFailed(String)
    /// The peer sent something that doesn't follow the protocol.
    case protocolViolation(String)
    /// The operation took too long.
    case timeout
    /// The connection closed.
    case connectionClosed
    /// The peer declined a request, for example the user canceled text entry.
    case declined
    /// No paired companion is connected to answer a request.
    case noConnectedDevices
    /// The pairing link or QR code isn't valid.
    case invalidPairingLink
    /// A network error.
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .incorrectCode: "The code doesn't match. Check the code on the TV and try again."
        case .pairingNotAvailable: "The TV isn't ready to pair. Open its pairing screen and try again."
        case .notPaired: "This device isn't paired. Pair it again."
        case .handshakeFailed(let reason): "Couldn't establish a secure connection: \(reason)."
        case .protocolViolation(let reason): "The other device sent an invalid message: \(reason)."
        case .timeout: "The operation timed out."
        case .connectionClosed: "The connection closed."
        case .declined: "The request was declined."
        case .noConnectedDevices: "No paired device is connected."
        case .invalidPairingLink: "The pairing code isn't valid."
        case .network(let reason): "Network error: \(reason)"
        }
    }
}
