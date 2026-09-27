import Foundation

/// Asks a companion device to type text, such as a search, a server URL
/// or a password, using its own keyboard.
public struct TextInputRequest: Codable, Sendable, Hashable {
    public enum ContentType: String, Codable, Sendable {
        case plain, url, email, username, password, number, oneTimeCode, search
    }

    /// What's being asked for, such as "Server Address".
    public var prompt: String
    /// Optional extra explanation.
    public var message: String?
    public var initialText: String
    public var placeholder: String?
    public var contentType: ContentType

    public init(prompt: String, message: String? = nil, initialText: String = "", placeholder: String? = nil, contentType: ContentType = .plain) {
        self.prompt = prompt
        self.message = message
        self.initialText = initialText
        self.placeholder = placeholder
        self.contentType = contentType
    }

    /// Whether the text should be hidden while typing.
    public var isSecure: Bool { contentType == .password }

    static let type = "tvcompanion.text"
}

struct TextInputResponse: Codable, Sendable {
    var text: String
}

/// Asks a companion device for sign-in details, which it can fill from its
/// own password manager (AutoFill) instead of typing on the TV.
public struct CredentialRequest: Codable, Sendable, Hashable {
    /// A description of what the credentials are for, such as "Jellyfin".
    public var service: String
    /// The server, if known, so the companion can suggest saved passwords.
    public var serverURL: URL?
    /// A username to prefill.
    public var username: String?

    public init(service: String, serverURL: URL? = nil, username: String? = nil) {
        self.service = service
        self.serverURL = serverURL
        self.username = username
    }

    static let type = "tvcompanion.credentials"
}

/// Credentials returned by a companion device.
public struct CompanionCredential: Codable, Sendable, Hashable {
    public var username: String
    public var password: String
    public var serverURL: URL?

    public init(username: String, password: String, serverURL: URL? = nil) {
        self.username = username
        self.password = password
        self.serverURL = serverURL
    }
}

extension CompanionSession {
    /// Asks the companion to type text. Throws ``CompanionError/declined``
    /// if the user cancels.
    public func requestText(_ request: TextInputRequest, timeout: Duration = .seconds(300)) async throws -> String {
        try await self.request(TextInputRequest.type, request, as: TextInputResponse.self, timeout: timeout).text
    }

    /// Asks the companion for credentials.
    public func requestCredentials(_ request: CredentialRequest, timeout: Duration = .seconds(300)) async throws -> CompanionCredential {
        try await self.request(CredentialRequest.type, request, as: CompanionCredential.self, timeout: timeout)
    }
}

extension CompanionRequest {
    /// The text input request, if this is one.
    public var textInput: TextInputRequest? {
        type == TextInputRequest.type ? try? decode(TextInputRequest.self) : nil
    }

    /// The credential request, if this is one.
    public var credentialRequest: CredentialRequest? {
        type == CredentialRequest.type ? try? decode(CredentialRequest.self) : nil
    }

    /// Answers a text input request.
    public func respond(text: String) async throws {
        try await respond(TextInputResponse(text: text))
    }

    /// Answers a credential request.
    public func respond(credential: CompanionCredential) async throws {
        try await respond(credential as CompanionCredential)
    }
}
