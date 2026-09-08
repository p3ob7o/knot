import Foundation

public enum PathValidationError: Error, Equatable, LocalizedError, Sendable {
    case emptyFilename
    case absolutePath
    case parentTraversal
    case currentDirectoryComponent
    case ambiguousSeparator
    case emptyComponent
    case controlCharacter
    case componentTooLong
    case pathTooLong
    case invalidGeneratedName

    public var errorDescription: String? {
        switch self {
        case .emptyFilename: "A filename is required."
        case .absolutePath: "Paths must stay relative to the selected vault."
        case .parentTraversal: "Parent path components are not allowed."
        case .currentDirectoryComponent: "Current-directory components are not allowed."
        case .ambiguousSeparator: "Use forward slashes as folder separators."
        case .emptyComponent: "Empty path components are not allowed."
        case .controlCharacter: "Control characters are not allowed in paths."
        case .componentTooLong: "A path component is too long."
        case .pathTooLong: "The path is too long."
        case .invalidGeneratedName: "The generated filename is not safe."
        }
    }
}

public struct VaultRelativePath: Codable, Hashable, Sendable, CustomStringConvertible {
    public enum Kind: Sendable {
        case folder
        case file
    }

    public static let root = try! VaultRelativePath("", kind: .folder)
    public let components: [String]

    public var string: String { components.joined(separator: "/") }
    public var description: String { string }
    public var isRoot: Bool { components.isEmpty }
    public var lastComponent: String? { components.last }

    public init(_ rawValue: String, kind: Kind = .folder) throws {
        guard rawValue.utf8.count <= 4_096 else { throw PathValidationError.pathTooLong }
        if rawValue.isEmpty {
            guard kind == .folder else { throw PathValidationError.emptyFilename }
            components = []
            return
        }
        guard !rawValue.hasPrefix("/"),
              !rawValue.hasPrefix("~"),
              !(rawValue.count >= 2 && rawValue.dropFirst().first == ":" && rawValue.first?.isLetter == true) else {
            throw PathValidationError.absolutePath
        }
        guard !rawValue.contains("\\") else { throw PathValidationError.ambiguousSeparator }
        let split = rawValue.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !split.contains(where: \.isEmpty) else { throw PathValidationError.emptyComponent }
        var checked: [String] = []
        checked.reserveCapacity(split.count)
        for component in split {
            if component == ".." { throw PathValidationError.parentTraversal }
            if component == "." { throw PathValidationError.currentDirectoryComponent }
            guard !component.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0) || $0.value == 0
            }) else {
                throw PathValidationError.controlCharacter
            }
            guard component.utf8.count <= 255 else { throw PathValidationError.componentTooLong }
            checked.append(component)
        }
        if kind == .file, checked.last?.isEmpty != false {
            throw PathValidationError.emptyFilename
        }
        components = checked
    }

    public init(components: [String], kind: Kind = .folder) throws {
        try self.init(components.joined(separator: "/"), kind: kind)
    }

    public func appending(_ child: VaultRelativePath) throws -> VaultRelativePath {
        try VaultRelativePath(components: components + child.components, kind: child.isRoot ? .folder : .file)
    }

    public func appending(component: String, kind: Kind) throws -> VaultRelativePath {
        try VaultRelativePath(components: components + [component], kind: kind)
    }

    public var parent: VaultRelativePath {
        (try? VaultRelativePath(components: Array(components.dropLast()), kind: .folder)) ?? .root
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        try self.init(raw, kind: .folder)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}

public enum AttachmentDestination: Codable, Equatable, Sendable {
    case vaultRoot
    case vaultRelative(VaultRelativePath)
    case besideNote
    case besideNoteSubfolder(VaultRelativePath)

    public init(obsidianValue: String) throws {
        let value = obsidianValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "", "/":
            self = .vaultRoot
        case ".":
            self = .besideNote
        default:
            if value.hasPrefix("./") {
                let suffix = String(value.dropFirst(2))
                self = .besideNoteSubfolder(try VaultRelativePath(suffix, kind: .folder))
            } else {
                self = .vaultRelative(try VaultRelativePath(value, kind: .folder))
            }
        }
    }
}

public enum SafeFilename {
    private static let forbidden = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.controlCharacters)

    public static func stem(from input: String, maximumBytes: Int = 180) throws -> String {
        var value = String(input.unicodeScalars.map { forbidden.contains($0) ? "-" : Character($0) })
        while value.contains("--") { value = value.replacingOccurrences(of: "--", with: "-") }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: " .-").union(.whitespaces))
        guard !value.isEmpty else { throw PathValidationError.invalidGeneratedName }
        guard value.utf8.count > maximumBytes else { return value }

        let suffix = "-" + String(fnv1a64(input), radix: 16).suffix(8)
        let budget = maximumBytes - suffix.utf8.count
        var prefix = ""
        for character in value {
            guard prefix.utf8.count + String(character).utf8.count <= budget else { break }
            prefix.append(character)
        }
        prefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        guard !prefix.isEmpty else { throw PathValidationError.invalidGeneratedName }
        return prefix + suffix
    }

    private static func fnv1a64(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}
