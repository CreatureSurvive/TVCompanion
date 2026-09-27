import SwiftUI
import TVCompanion

@main
struct DemoTVApp: App {
    @State private var companion = CompanionHost(
        name: ProcessInfo.processInfo.arguments.contains("-testing") ? "Test TV" : "Living Room",
        serviceType: "_tvcdemo._tcp",
        linkScheme: "tvcompaniondemo",
        store: ProcessInfo.processInfo.arguments.contains("-testing") || ProcessInfo.processInfo.arguments.contains("-screenshots") ? InMemoryPairingStore() : KeychainPairingStore(service: "TVCompanionDemo")
    )

    var body: some Scene {
        WindowGroup {
            ContentView(companion: companion)
                .task { try? companion.start() }
                .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-dark") ? .dark : nil)
        }
    }
}

struct ContentView: View {
    let companion: CompanionHost
    @State private var address = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 30) {
                NavigationLink("Pair iPhone") {
                    CompanionPairingView(host: companion, appName: "Companion")
                }
                .accessibilityIdentifier("pairButton")
                HStack(spacing: 30) {
                    TextField("Server Address", text: $address)
                        .accessibilityIdentifier("addressField")
                    CompanionTypeButton(host: companion, text: $address, request: TextInputRequest(prompt: "Server Address", contentType: .url))
                        .accessibilityIdentifier("typeOnPhone")
                }
                Text("Server: \(address.isEmpty ? "none" : address)")
                    .accessibilityIdentifier("serverValue")
                Text("Connected: \(companion.connectedDevices.map(\.name).joined(separator: ", "))")
                    .accessibilityIdentifier("connectedDevices")
                if !companion.pairedDevices.isEmpty {
                    Section("Paired Devices") {
                        ForEach(companion.pairedDevices) { device in
                            Button("Unpair \(device.name)") { companion.unpair(device) }
                        }
                    }
                }
            }
            .padding(80)
        }
    }
}
