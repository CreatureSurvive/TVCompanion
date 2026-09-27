import SwiftUI
import TVCompanion

@main
struct DemoPhoneApp: App {
    var body: some Scene {
        WindowGroup { PhoneView() }
    }
}

struct PhoneView: View {
    @State private var hosts: [DiscoveredHost] = []
    @State private var session: CompanionSession?
    @State private var pairing: PairingAttempt?
    @State private var error: String?
    private let companion = CompanionClient(name: UIDevice.current.name, serviceType: "_tvcdemo._tcp", store: KeychainPairingStore(service: "TVCompanionDemo"))

    var body: some View {
        NavigationStack {
            List {
                if let session {
                    Section("Connected") {
                        Label(session.peer.name, systemImage: "appletv.fill")
                        Button("Disconnect") { Task { await session.close(); self.session = nil } }
                    }
                }
                Section("Apple TVs") {
                    if hosts.isEmpty { Text("Searching…").foregroundStyle(.secondary) }
                    ForEach(hosts) { host in
                        Button {
                            select(host)
                        } label: {
                            LabeledContent(host.name, value: host.isPaired ? "Paired" : "Pair")
                        }
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("Companion")
            .task { for await list in companion.discover() { hosts = list } }
            .sheet(item: $pairing) { attempt in
                PairingCodeEntryView(attempt: attempt) { session = $0 }
                    .presentationDetents([.medium])
            }
            .companionRequests(from: session)
            .onOpenURL { url in
                Task {
                    do {
                        session = try await companion.pair(using: PairingLink(url: url))
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
        }
    }

    private func select(_ host: DiscoveredHost) {
        error = nil
        if host.isPaired {
            Task {
                do { session = try await companion.connect(to: host) } catch { self.error = error.localizedDescription }
            }
        } else {
            pairing = companion.pair(with: host)
        }
    }
}
