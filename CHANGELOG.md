# Changelog

## 1.0.1

- `PairingAttempt.cancel()` does nothing once pairing has finished. `PairingCodeEntryView`
  cancels its attempt when it disappears, which happens right after a successful pairing, so
  sessions paired through it were disconnected immediately.
- The example has an iOS UI test target in which the test process plays the Apple TV, and UI
  tests that capture the README screenshots.

## 1.0.0

- Initial release: local-network pairing between Apple TV and iPhone (numeric-comparison code
  pairing with commitments, or single-use QR secrets), Ed25519 identities with signed
  reconnection, a ChaCha20-Poly1305 channel, text and credential requests with
  first-answer-wins across devices, generic messages and requests, Bonjour discovery, and
  SwiftUI views for both sides.
