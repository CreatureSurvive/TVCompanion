# TVCompanion

[![CI](https://github.com/CreatureSurvive/TVCompanion/actions/workflows/ci.yml/badge.svg)](https://github.com/CreatureSurvive/TVCompanion/actions/workflows/ci.yml)
[![Swift 6.1+](https://img.shields.io/badge/Swift-6.1+-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20macOS%20%7C%20tvOS%20%7C%20visionOS-blue)](#requirements)
[![Swift Package Manager](https://img.shields.io/badge/SwiftPM-compatible-brightgreen)](#installation)
[![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)

"Type on your iPhone" for Apple TV apps: secure local pairing between a tvOS app and its iOS
companion, so users can type text, send passwords from AutoFill, or control the TV app from
their phone.

```swift
// tvOS
let address = try await companion.requestText(TextInputRequest(prompt: "Server Address", contentType: .url))

// iOS: the request appears as a sheet with the right keyboard and AutoFill
ContentView().companionRequests(from: session)
```

## Why

Typing on Apple TV is painful. Server addresses, usernames and passwords are the worst part of
every self-hosted media app's setup. Apple's Continuity Keyboard only works for system text
fields in the foreground and can't fill passwords from the phone's password manager for your
own sign-in flow. Rolling your own phone-to-TV channel means handling discovery, pairing, and
above all security: anything on the Wi-Fi network can connect to an open port.

TVCompanion does all of it:

- **Discovery** over Bonjour, including peer-to-peer Wi-Fi.
- **Pairing** by comparing a 6-digit code, or by scanning a QR code with the iPhone's Camera
  app.
- **Reconnection** without user interaction, authenticated by device keys stored in the
  keychain.
- **An encrypted channel** for messages and requests.
- **Built-in requests** for text input (with content types for URL, email, password, one-time
  code, number and search keyboards) and credentials, with SwiftUI views on both ends.

## Security

The protocol is small and uses only CryptoKit:

| Step | Mechanism |
| --- | --- |
| Key agreement | Ephemeral X25519 each connection (forward secrecy) |
| Commitment | The phone commits to its key (SHA-256) before seeing the TV's, so an attacker can't try keys until the codes collide |
| Code pairing | Both devices derive a 6-digit code from the key agreement and transcript. The phone checks the TV's code, and the TV's user confirms it. An active man-in-the-middle is detected unless two independent codes collide (1 in 10⁶ per attempt). Pairing locks after 5 failures. |
| QR pairing | A single-use 128-bit secret from the TV's screen is mixed into the keys. Only someone who can see the screen can pair. |
| Identity | Each device has an Ed25519 key in the keychain (device-only). Reconnections sign the handshake transcript. |
| Channel | ChaCha20-Poly1305 with per-direction keys and counter nonces. Modified, replayed, reordered or reflected messages are rejected. |

Why the TV also asks for confirmation: a code checked only on the phone protects the phone, but
any device on the network could compute its own session's code and pair with the TV while its
pairing screen is open. Requiring the TV's user to confirm that their phone shows the same code
is the numeric-comparison design used by Bluetooth LE Secure Connections.

The tests attack the protocol directly. They cover:

- an active man-in-the-middle, where the user types the real TV's code
- a rogue client pairing without the TV user's approval
- a broken commitment
- a wrong QR secret, and a QR code for another TV
- an impostor phone with a stolen ID
- an impostor TV
- channel tampering, replay, reordering and reflection
- low-order keys

## Usage

### tvOS

```swift
@main
struct MyTVApp: App {
    @State private var companion = CompanionHost(name: "Living Room", serviceType: "_myapp-companion._tcp", linkScheme: "myapp")

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(companion)
                .task { try? companion.start() }
        }
    }
}

// Settings → Pair iPhone
CompanionPairingView(host: companion, appName: "My App")

// Next to any text field
CompanionTypeButton(host: companion, text: $password, request: TextInputRequest(prompt: "Password", contentType: .password))

// Sign-in with credentials from the phone's password manager
let login = try await companion.requestCredentials(CredentialRequest(service: "Jellyfin", serverURL: serverURL))
```

### iOS

```swift
let companion = CompanionClient(name: UIDevice.current.name, serviceType: "_myapp-companion._tcp")

for await hosts in companion.discover() { tvs = hosts }

// Pair with a code: start the attempt, then show the code-entry sheet
pairing = companion.pair(with: tv)
// …
.sheet(item: $pairing) { attempt in
    PairingCodeEntryView(attempt: attempt) { session = $0 }
}

// Or with the QR code (the Camera app opens your app through linkScheme)
.onOpenURL { url in
    Task { session = try? await companion.pair(using: PairingLink(url: url)) }
}

// Later
session = try await companion.connect(to: tv)

// Answer the TV's requests with built-in UI
.companionRequests(from: session)
```

Add `NSLocalNetworkUsageDescription` and your service type in `NSBonjourServices` to the iOS
app's `Info.plist`. tvOS has no local network prompt.

### Custom messages and requests

```swift
// Either side
try await session.send("play", PlayCommand(itemID: id))
let status = try await session.request("status", StatusQuery(), as: PlayerStatus.self)

for await request in session.requests where request.type == "status" {
    try await request.respond(currentStatus)
}
```

## Installation

Add TVCompanion to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/CreatureSurvive/TVCompanion.git", from: "1.0.0"),
],
targets: [
    .target(name: "MyApp", dependencies: ["TVCompanion"]),
]
```

Or in Xcode, choose **File › Add Package Dependencies…** and enter
`https://github.com/CreatureSurvive/TVCompanion`.

### Requirements

| Platform | Minimum |
| --- | --- |
| iOS | 17.0 |
| macOS | 14.0 |
| tvOS | 17.0 |
| visionOS | 1.0 |

Swift 6.1 (Xcode 16.4) or later, in Swift 6 language mode. No third-party dependencies.

## Testing

- `swift test` runs 32 tests:
  - the protocol, attacked as described above, over in-memory transports
  - end-to-end host and client tests over real TCP on this machine: code pairing with TV
    confirmation, a wrong code and retry, TV rejection, pairing closed by default, QR pairing
    (single-use), reconnection, unpairing, text and credential requests, first-answer-wins
    across two phones, and messages both ways
  - Bonjour discovery with pairing through the discovered endpoint

  The suite is clean under Thread Sanitizer.
- `Example/` has a tvOS app, an iOS app, and a tvOS UI test in which the test process plays the
  phone:
  1. It discovers the TV app over Bonjour.
  2. It reads the pairing code from the TV screen.
  3. It pairs once Confirm is pressed with the Siri Remote.
  4. It answers "Type on iPhone", and the TV shows the typed server address.

```sh
cd Example && xcodegen generate
xcodebuild test -project TVCompanionDemo.xcodeproj -scheme DemoTV \
  -destination "platform=tvOS Simulator,name=Apple TV 4K (3rd generation)"
```

To try it on hardware, run `DemoTV` on an Apple TV and `DemoPhone` on an iPhone on the same
network.

## Limitations

- Both devices must be on the same local network, or near each other for peer-to-peer Wi-Fi.
- The phone app has to be running (foreground) to answer requests.
- Device names are sent in the clear during the handshake. Everything after it is encrypted.

## Changelog

See [CHANGELOG.md](CHANGELOG.md). Releases follow [Semantic Versioning](https://semver.org).

## Contributing

Issues and pull requests are welcome. Please run `swift test` before opening a pull request, and
add tests for new behavior. Report security issues privately; see [SECURITY.md](SECURITY.md).

## License

Available under the MIT license. See [LICENSE](LICENSE) for details.
