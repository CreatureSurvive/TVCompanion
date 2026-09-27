import SwiftUI

/// Code entry for pairing with a TV. Shows a field once the TV is showing
/// its code, and reports mismatches.
///
/// ```swift
/// .sheet(item: $pairing) { attempt in
///     PairingCodeEntryView(attempt: attempt) { session in connected(session) }
/// }
/// ```
public struct PairingCodeEntryView: View {
    let attempt: PairingAttempt
    let onPaired: (CompanionSession) -> Void
    @State private var hostName: String?
    @State private var code = ""
    @State private var message: String?
    @State private var isVerifying = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    public init(attempt: PairingAttempt, onPaired: @escaping (CompanionSession) -> Void) {
        self.attempt = attempt
        self.onPaired = onPaired
    }

    public var body: some View {
        VStack(spacing: 20) {
            if let failure {
                ContentUnavailableView("Couldn't Pair", systemImage: "exclamationmark.triangle", description: Text(failure))
                Button("Close") { dismiss() }
            } else if let hostName {
                Text("Enter the code shown on \(hostName)")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                TextField("000000", text: $code)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    #if os(iOS) || os(visionOS)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    #endif
                    .onChange(of: code) { _, value in
                        code = String(value.filter(\.isNumber).prefix(6))
                        if code.count == 6 { submit() }
                    }
                    .disabled(isVerifying)
                if isVerifying {
                    ProgressView("Confirm on the TV…")
                } else if let message {
                    Text(message).foregroundStyle(.red).font(.callout)
                }
            } else {
                ProgressView("Connecting…")
            }
        }
        .padding()
        .task {
            do {
                hostName = try await attempt.codeRequested()
            } catch {
                failure = error.localizedDescription
            }
        }
        .onDisappear {
            Task { await attempt.cancel() }
        }
    }

    private func submit() {
        let entered = code
        isVerifying = true
        message = nil
        Task {
            do {
                let session = try await attempt.submit(code: entered)
                onPaired(session)
                dismiss()
            } catch CompanionError.incorrectCode {
                isVerifying = false
                code = ""
                message = CompanionError.incorrectCode.localizedDescription
            } catch {
                isVerifying = false
                failure = error.localizedDescription
            }
        }
    }
}

extension PairingAttempt: Identifiable {
    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

/// Answers a request from the TV: a text field for text input (secure for
/// passwords), or username and password fields for credentials, with
/// AutoFill.
public struct CompanionRequestView: View {
    let request: CompanionRequest
    let onFinish: () -> Void
    @State private var text = ""
    @State private var username = ""
    @State private var password = ""

    public init(request: CompanionRequest, onFinish: @escaping () -> Void = {}) {
        self.request = request
        self.onFinish = onFinish
    }

    public var body: some View {
        NavigationStack {
            Form {
                if let input = request.textInput {
                    Section {
                        field(input)
                    } header: {
                        Text(input.prompt)
                    } footer: {
                        if let message = input.message { Text(message) }
                    }
                } else if let credentials = request.credentialRequest {
                    Section {
                        TextField("Username", text: $username)
                            #if os(iOS) || os(visionOS)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                            #if os(iOS) || os(visionOS)
                            .textContentType(.password)
                            #endif
                    } header: {
                        Text("Sign in to \(credentials.service)")
                    } footer: {
                        if let url = credentials.serverURL { Text(url.absoluteString) }
                    }
                } else {
                    Text("This request isn't supported.")
                }
            }
            .navigationTitle("Apple TV")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { finish { await request.decline() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send() }.disabled(!canSend)
                }
            }
        }
        .onAppear {
            text = request.textInput?.initialText ?? ""
            username = request.credentialRequest?.username ?? ""
        }
    }

    @ViewBuilder
    private func field(_ input: TextInputRequest) -> some View {
        if input.isSecure {
            SecureField(input.placeholder ?? input.prompt, text: $text)
                #if os(iOS) || os(visionOS)
                .textContentType(.password)
                #endif
                .onSubmit(send)
        } else {
            TextField(input.placeholder ?? input.prompt, text: $text)
                #if os(iOS) || os(visionOS)
                .keyboardType(Self.keyboard(for: input.contentType))
                .textContentType(Self.contentType(for: input.contentType))
                .textInputAutocapitalization(input.contentType == .plain || input.contentType == .search ? .sentences : .never)
                #endif
                .autocorrectionDisabled(input.contentType != .plain)
                .onSubmit(send)
        }
    }

    private var canSend: Bool {
        request.credentialRequest != nil ? !username.isEmpty && !password.isEmpty : true
    }

    private func send() {
        guard canSend else { return }
        finish {
            if request.credentialRequest != nil {
                try? await request.respond(credential: CompanionCredential(username: username, password: password, serverURL: request.credentialRequest?.serverURL))
            } else {
                try? await request.respond(text: text)
            }
        }
    }

    private func finish(_ action: @escaping @Sendable () async -> Void) {
        Task {
            await action()
            onFinish()
        }
    }

    #if os(iOS) || os(visionOS)
    static func keyboard(for type: TextInputRequest.ContentType) -> UIKeyboardType {
        switch type {
        case .url: .URL
        case .email: .emailAddress
        case .number, .oneTimeCode: .numberPad
        case .search: .webSearch
        default: .default
        }
    }

    static func contentType(for type: TextInputRequest.ContentType) -> UITextContentType? {
        switch type {
        case .url: .URL
        case .email: .emailAddress
        case .username: .username
        case .password: .password
        case .oneTimeCode: .oneTimeCode
        default: nil
        }
    }
    #endif
}

extension View {
    /// Presents ``CompanionRequestView`` for each request the session
    /// receives. This consumes `session.requests`, so don't iterate it
    /// elsewhere.
    public func companionRequests(from session: CompanionSession?) -> some View {
        modifier(CompanionRequestPresenter(session: session))
    }
}

struct CompanionRequestPresenter: ViewModifier {
    let session: CompanionSession?
    @State private var current: IdentifiedRequest?
    @State private var queue: [IdentifiedRequest] = []

    struct IdentifiedRequest: Identifiable {
        let id = UUID()
        let request: CompanionRequest
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: $current, onDismiss: showNext) { item in
                CompanionRequestView(request: item.request) { current = nil }
            }
            .task(id: session.map(ObjectIdentifier.init)) {
                guard let session else { return }
                let cancellations = Task { @MainActor in
                    for await id in session.cancellations {
                        queue.removeAll { $0.request.id == id }
                        if current?.request.id == id { current = nil }
                    }
                }
                defer { cancellations.cancel() }
                for await request in session.requests {
                    let item = IdentifiedRequest(request: request)
                    if current == nil { current = item } else { queue.append(item) }
                }
            }
    }

    private func showNext() {
        if !queue.isEmpty { current = queue.removeFirst() }
    }
}
