import CoreImage.CIFilterBuiltins
import SwiftUI

/// The TV's pairing screen. It opens pairing while visible, shows a QR code
/// and instructions, then the code to compare, with Confirm and Cancel
/// buttons.
///
/// ```swift
/// NavigationLink("Pair iPhone") { CompanionPairingView(host: companion, appName: "Gelo") }
/// ```
public struct CompanionPairingView: View {
    let host: CompanionHost
    let appName: String
    @FocusState private var confirmFocused: Bool

    /// - Parameter appName: The companion app's name, used in the instructions.
    public init(host: CompanionHost, appName: String) {
        self.host = host
        self.appName = appName
    }

    public var body: some View {
        VStack(spacing: 32) {
            switch host.pairingState {
            case .closed, .waiting:
                waiting
            case .showingCode(let code, let deviceName):
                confirming(code: code, deviceName: deviceName)
            case .paired(let device):
                Label("\(device.name) is paired", systemImage: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                Button("Done") { host.closePairing() }
            case .locked:
                Label("Pairing paused after too many attempts", systemImage: "lock.fill")
                    .font(.title3)
                Button("Try Again") { host.openPairing() }
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { host.openPairing() }
        .onDisappear { host.closePairing() }
    }

    @ViewBuilder
    private var waiting: some View {
        HStack(alignment: .center, spacing: 60) {
            if let link = host.pairingLink {
                QRCodeView(url: link)
                    .frame(width: 280, height: 280)
                    .accessibilityLabel("Pairing QR code")
            }
            VStack(alignment: .leading, spacing: 16) {
                Text("Pair Your iPhone").font(.title2.bold())
                Text("Scan the code with your iPhone's camera, or open \(appName) on your iPhone and choose **\(host.name)**.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 700, alignment: .leading)
        }
    }

    @ViewBuilder
    private func confirming(code: String, deviceName: String) -> some View {
        Text("Pairing with \(deviceName)").font(.title3)
        Text(Self.spaced(code))
            .font(.system(size: 96, weight: .bold, design: .rounded))
            .monospacedDigit()
            .accessibilityIdentifier("pairingCode")
            .accessibilityLabel(code.map(String.init).joined(separator: " "))
        Text("Check that \(deviceName) shows the same code.")
            .foregroundStyle(.secondary)
        HStack(spacing: 40) {
            Button("Confirm") { host.confirmPairing() }
                .accessibilityIdentifier("confirmPairing")
                .focused($confirmFocused)
            Button("Cancel", role: .cancel) { host.rejectPairing() }
        }
        .defaultFocus($confirmFocused, true)
        .task(id: code) {
            // The waiting screen has nothing focusable, so default focus
            // doesn't apply when the buttons appear; request it.
            for _ in 0..<20 where !confirmFocused {
                confirmFocused = true
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    static func spaced(_ code: String) -> String {
        code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }
}

/// A button for a TV text field that lets the user type on a paired phone.
///
/// ```swift
/// HStack {
///     TextField("Server Address", text: $address)
///     CompanionTypeButton(host: companion, text: $address, request: TextInputRequest(prompt: "Server Address", contentType: .url))
/// }
/// ```
///
/// It's hidden while no paired device is connected.
public struct CompanionTypeButton: View {
    let host: CompanionHost
    @Binding var text: String
    let request: TextInputRequest
    @State private var isWaiting = false

    public init(host: CompanionHost, text: Binding<String>, request: TextInputRequest) {
        self.host = host
        _text = text
        self.request = request
    }

    public var body: some View {
        if !host.connectedDevices.isEmpty {
            Button {
                Task {
                    isWaiting = true
                    defer { isWaiting = false }
                    var request = request
                    request.initialText = text
                    if let typed = try? await host.requestText(request) { text = typed }
                }
            } label: {
                Label(isWaiting ? "Waiting for iPhone…" : "Type on iPhone", systemImage: "iphone")
            }
            .disabled(isWaiting)
        }
    }
}

/// Renders a URL as a QR code.
public struct QRCodeView: View {
    let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var body: some View {
        if let image = Self.image(for: url.absoluteString) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(16)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    static func image(for string: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
