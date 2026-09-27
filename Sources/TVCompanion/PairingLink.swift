import CryptoKit
import Foundation

/// The contents of the host's pairing QR code.
///
/// It carries the host's identity and a single-use 128-bit secret, so a
/// phone that scans it pairs without a code. Use your app's URL scheme so
/// the iPhone Camera app opens your companion app directly.
public struct PairingLink: Sendable, Hashable {
    public var hostID: String
    public var hostName: String
    public var serviceType: String
    let secret: SymmetricKey

    public static func == (lhs: PairingLink, rhs: PairingLink) -> Bool {
        lhs.hostID == rhs.hostID && lhs.serviceType == rhs.serviceType
            && lhs.secret.withUnsafeBytes { Data($0) } == rhs.secret.withUnsafeBytes { Data($0) }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(hostID)
    }

    init(hostID: String, hostName: String, serviceType: String, secret: SymmetricKey) {
        self.hostID = hostID
        self.hostName = hostName
        self.serviceType = serviceType
        self.secret = secret
    }

    /// Parses a scanned pairing URL.
    public init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.host == "pair" else {
            throw CompanionError.invalidPairingLink
        }
        let items = Dictionary((components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { a, _ in a })
        guard let hostID = items["host"], !hostID.isEmpty,
              let service = items["service"], !service.isEmpty,
              let encoded = items["secret"], let secretData = Data(base64URLEncoded: encoded), secretData.count == 16
        else { throw CompanionError.invalidPairingLink }
        self.init(hostID: hostID, hostName: items["name"] ?? "TV", serviceType: service, secret: SymmetricKey(data: secretData))
    }

    /// The URL to encode in the QR code.
    public func url(scheme: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "host", value: hostID),
            URLQueryItem(name: "name", value: hostName),
            URLQueryItem(name: "service", value: serviceType),
            URLQueryItem(name: "secret", value: secret.withUnsafeBytes { Data($0) }.base64URLEncodedString()),
        ]
        return components.url!
    }
}

extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
