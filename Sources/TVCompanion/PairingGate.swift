import CryptoKit
import Foundation

/// What the host's pairing screen should show.
public enum PairingState: Sendable, Equatable {
    /// Not accepting new pairings.
    case closed
    /// Waiting for a device. Show ``CompanionHost/pairingLink`` as a QR code
    /// and ask the user to choose this TV in the companion app.
    case waiting
    /// A device is pairing. Show the code, which the user checks against
    /// their device, then call ``CompanionHost/confirmPairing()`` or
    /// ``CompanionHost/rejectPairing()``.
    case showingCode(code: String, deviceName: String)
    /// A device paired successfully.
    case paired(PairedDevice)
    /// Pairing was stopped after too many failed attempts.
    case locked
}

/// Controls which pairing attempts the host accepts.
///
/// Pairing is only possible while the pairing screen is open, one attempt at
/// a time, and it locks after repeated failures (each wrong code or failed
/// verification). A QR secret is single-use: a new one is generated after
/// every attempt.
actor PairingGate {
    struct Attempt: Sendable, Equatable {
        let id = UUID()
        let mode: HandshakeMode
        let secret: SymmetricKey?

        static func == (lhs: Attempt, rhs: Attempt) -> Bool { lhs.id == rhs.id }
    }

    static let maximumFailures = 5

    private(set) var isOpen = false
    private(set) var secret = SymmetricKey(size: .bits128)
    private var current: Attempt?
    private var failures = 0
    private var confirmation: CheckedContinuation<Void, any Error>?
    /// The local user's answer, if it arrived before the handshake asked.
    private var answer: Bool?
    private let onChange: @Sendable (PairingState, SymmetricKey?) -> Void

    init(onChange: @escaping @Sendable (PairingState, SymmetricKey?) -> Void = { _, _ in }) {
        self.onChange = onChange
    }

    func open() {
        isOpen = true
        failures = 0
        secret = SymmetricKey(size: .bits128)
        onChange(.waiting, secret)
    }

    func close() {
        isOpen = false
        current = nil
        resolveConfirmation(with: CompanionError.pairingNotAvailable)
        onChange(.closed, nil)
    }

    /// Waits for the person at the host to confirm that the code shown
    /// matches their device. Required for code pairing: the code protects
    /// the client from interception, and this confirmation stops other
    /// devices on the network from pairing with the host.
    func waitForConfirmation(_ attempt: Attempt) async throws {
        guard current == attempt else { throw CompanionError.pairingNotAvailable }
        if let answer {
            self.answer = nil
            if answer { return } else { throw CompanionError.declined }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                confirmation = continuation
            }
        } onCancel: {
            Task { await self.resolveConfirmation(with: CancellationError()) }
        }
    }

    /// The person at the host confirmed the code.
    func confirm() {
        guard current != nil else { return }
        if let confirmation {
            self.confirmation = nil
            confirmation.resume()
        } else {
            answer = true
        }
    }

    /// The person at the host rejected the code.
    func reject() {
        guard current != nil else { return }
        if confirmation != nil {
            resolveConfirmation(with: CompanionError.declined)
        } else {
            answer = false
        }
    }

    private func resolveConfirmation(with error: any Error) {
        let pending = confirmation
        confirmation = nil
        pending?.resume(throwing: error)
    }

    func begin(mode: HandshakeMode, clientName: String) throws -> Attempt {
        guard isOpen, failures < Self.maximumFailures else { throw CompanionError.pairingNotAvailable }
        guard current == nil else { throw CompanionError.pairingNotAvailable }
        let attempt = Attempt(mode: mode, secret: mode == .pairSecret ? secret : nil)
        current = attempt
        answer = nil
        return attempt
    }

    func showCode(_ code: String, deviceName: String, for attempt: Attempt) {
        guard current == attempt else { return }
        onChange(.showingCode(code: code, deviceName: deviceName), nil)
    }

    func succeed(_ attempt: Attempt, device: PairedDevice) {
        guard current == attempt else { return }
        current = nil
        answer = nil
        failures = 0
        rotateSecret()
        onChange(.paired(device), secret)
    }

    func fail(_ attempt: Attempt, error: any Error) {
        guard current == attempt else { return }
        current = nil
        answer = nil
        resolveConfirmation(with: error)
        // A dropped connection before the code was checked isn't a guess.
        if case CompanionError.connectionClosed = error {} else if error is CancellationError {} else {
            failures += 1
        }
        rotateSecret()
        if failures >= Self.maximumFailures {
            isOpen = false
            onChange(.locked, nil)
        } else if isOpen {
            onChange(.waiting, secret)
        }
    }

    /// QR secrets are single-use.
    private func rotateSecret() {
        secret = SymmetricKey(size: .bits128)
    }
}
