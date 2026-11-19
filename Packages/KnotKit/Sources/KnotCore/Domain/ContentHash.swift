import CryptoKit
import Foundation

/// A secret of one store, kept in its `store_meta` row, that keys content hashes.
///
/// A content hash only has to tell whether a repeated capture ID brings the same content.
/// Keying it means the capture table, which the diagnostics export may read, never carries
/// a plain hash of what someone said or typed.
public struct StoreSecret: Hashable, Sendable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        precondition(bytes.count == 32, "A store secret has 32 bytes.")
        self.bytes = bytes
    }

    /// A new secret drawn from `generator`.
    public static func make(using generator: inout some RandomNumberGenerator) -> StoreSecret {
        StoreSecret(bytes: (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

/// The content of a finished capture, as the content hash reads it.
public enum CaptureContent: Hashable, Sendable {
    /// A typed capture, or text from the command line or MCP.
    case text(String)
    /// A recording or a drawing, named by the SHA-256 of its file.
    case file(sha256: [UInt8])
}

/// An HMAC-SHA256 of a capture's kind and content, keyed with the store's secret.
public struct ContentHash: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Lower-case hexadecimal.
    public let hex: String

    public init(hex: String) {
        self.hex = hex
    }

    public init(kind: SegmentKind, content: CaptureContent, secret: StoreSecret) {
        var message = Array(kind.rawValue.utf8)
        message.append(0)
        switch content {
        case .text(let text):
            message.append(contentsOf: Array("text".utf8))
            message.append(0)
            // Text that Swift calls equal hashes equal: the hash reads its NFC form, while
            // the stored text stays as it was given.
            message.append(contentsOf: Array(text.precomposedStringWithCanonicalMapping.utf8))
        case .file(let sha256):
            message.append(contentsOf: Array("file".utf8))
            message.append(0)
            message.append(contentsOf: sha256)
        }
        let code = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret.bytes))
        self.hex = code.map { String(format: "%02x", $0) }.joined()
    }

    public var description: String { hex }

    public init(from decoder: any Decoder) throws {
        self.hex = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}
