/// An enum whose values travel between builds: in the database, in synced records and in
/// inbox manifests.
///
/// A value that this build does not know is kept as `unknown` with its text, and never
/// dropped, so a newer Knot's case does not break an older one (docs/architecture.md §4).
/// Every synced enum conforms from WP-02's first PR on. The text form is stable: it is what
/// the store and the records hold.
public protocol OpenEnum: RawRepresentable, Codable, Hashable, Sendable where RawValue == String {
    /// Every raw value has a case: one this build knows, or `unknown`.
    init(rawValue: String)

    /// True when this build does not know the value.
    var isUnknown: Bool { get }
}

/// The kind of a capture and of the segment it becomes.
public enum SegmentKind: OpenEnum, CaseIterable {
    case typed
    case voice
    case ink
    case unknown(String)

    public static let allCases: [SegmentKind] = [.typed, .voice, .ink]

    public init(rawValue: String) {
        switch rawValue {
        case "typed": self = .typed
        case "voice": self = .voice
        case "ink": self = .ink
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .typed: "typed"
        case .voice: "voice"
        case .ink: "ink"
        case .unknown(let raw): raw
        }
    }

    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }
}

/// Where a segment came from: a device, or the command line or MCP on the Mac.
public enum SegmentOrigin: OpenEnum {
    case device(DeviceID)
    case cli
    case mcp
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "cli": self = .cli
        case "mcp": self = .mcp
        default:
            if rawValue.hasPrefix("device:"), let id = DeviceID(String(rawValue.dropFirst("device:".count))) {
                self = .device(id)
            } else {
                self = .unknown(rawValue)
            }
        }
    }

    public var rawValue: String {
        switch self {
        case .device(let id): "device:\(id)"
        case .cli: "cli"
        case .mcp: "mcp"
        case .unknown(let raw): raw
        }
    }

    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }

    /// True for the command line and MCP, whose captures never end one open in the app.
    public var isTool: Bool {
        switch self {
        case .cli, .mcp: true
        case .device, .unknown: false
        }
    }
}

/// Where the text a segment shows came from. Precedence among them is in `TextPrecedence`.
public enum TextOrigin: OpenEnum, CaseIterable {
    /// Typed by a person as the capture was made.
    case typed
    /// The transcript, as the transcriber wrote it.
    case rawTranscript
    /// The transcript after cleanup.
    case cleaned
    /// Changed by a person after the capture, in the app, the command line or MCP.
    case edited
    /// Recognised from handwriting.
    case recognised
    case unknown(String)

    public static let allCases: [TextOrigin] = [.typed, .rawTranscript, .cleaned, .edited, .recognised]

    public init(rawValue: String) {
        switch rawValue {
        case "typed": self = .typed
        case "raw_transcript": self = .rawTranscript
        case "cleaned": self = .cleaned
        case "edited": self = .edited
        case "recognised": self = .recognised
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .typed: "typed"
        case .rawTranscript: "raw_transcript"
        case .cleaned: "cleaned"
        case .edited: "edited"
        case .recognised: "recognised"
        case .unknown(let raw): raw
        }
    }

    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }
}

/// Who made a note's title.
public enum TitleOrigin: OpenEnum, CaseIterable {
    case none
    /// Proposed by cleanup. Dropped when it no longer fits its note.
    case generated
    /// Typed by a person. Never replaced and never dropped by Knot.
    case user
    case unknown(String)

    public static let allCases: [TitleOrigin] = [.none, .generated, .user]

    public init(rawValue: String) {
        switch rawValue {
        case "none": self = .none
        case "generated": self = .generated
        case "user": self = .user
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .none: "none"
        case .generated: "generated"
        case .user: "user"
        case .unknown(let raw): raw
        }
    }

    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }
}

/// The kind of file an asset holds.
public enum AssetKind: OpenEnum, CaseIterable {
    case audio
    case ink
    case unknown(String)

    public static let allCases: [AssetKind] = [.audio, .ink]

    public init(rawValue: String) {
        switch rawValue {
        case "audio": self = .audio
        case "ink": self = .ink
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .audio: "audio"
        case .ink: "ink"
        case .unknown(let raw): raw
        }
    }

    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }

    /// The extension of a stored file of this kind. A stored recording is AAC in `.m4a`
    /// (docs/architecture.md §8). WP-18 may rename the drawing's extension before ink ships.
    public var fileExtension: String {
        switch self {
        case .audio: "m4a"
        case .ink: "drawing"
        case .unknown: "bin"
        }
    }
}

/// Whether an asset's file is on this device (docs/architecture.md §4).
public enum AssetAvailability: OpenEnum, CaseIterable {
    case local
    case remote
    case downloading
    case unknown(String)

    public static let allCases: [AssetAvailability] = [.local, .remote, .downloading]

    public init(rawValue: String) {
        switch rawValue {
        case "local": self = .local
        case "remote": self = .remote
        case "downloading": self = .downloading
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .local: "local"
        case .remote: "remote"
        case .downloading: "downloading"
        case .unknown(let raw): raw
        }
    }

    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }
}

/// How far an asset's upload has gone, from the device that made it (docs/architecture.md §11).
///
/// The segment's record carries it, so another device can say "not uploaded yet" and never
/// shows a broken player.
public enum AssetUpload: OpenEnum, CaseIterable {
    case localOnly
    case uploading
    case published
    case unknown(String)

    public static let allCases: [AssetUpload] = [.localOnly, .uploading, .published]

    public init(rawValue: String) {
        switch rawValue {
        case "local_only": self = .localOnly
        case "uploading": self = .uploading
        case "published": self = .published
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .localOnly: "local_only"
        case .uploading: "uploading"
        case .published: "published"
        case .unknown(let raw): raw
        }
    }

    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }
}

/// The surface a capture was started on. Rule 15 of docs/product-spec.md §3 reads it: a
/// capture started on another surface ends the open one.
public enum CaptureSurface: OpenEnum, CaseIterable {
    /// The capture surface in the app, including the capture field of an open note.
    case app
    /// The floating panel on the Mac, by click, tap or hold of the hotkey.
    case macPanel
    /// The Mac's main window.
    case macWindow
    /// A button outside the app: the Action Button, a Lock Screen or Control Center control,
    /// a widget, a complication or the Live Activity.
    case control
    /// Siri and Shortcuts.
    case intent
    /// The Watch app.
    case watch
    /// The `knot` command.
    case commandLine
    /// The MCP server.
    case mcp
    case unknown(String)

    public static let allCases: [CaptureSurface] = [
        .app, .macPanel, .macWindow, .control, .intent, .watch, .commandLine, .mcp,
    ]

    public init(rawValue: String) {
        switch rawValue {
        case "app": self = .app
        case "mac_panel": self = .macPanel
        case "mac_window": self = .macWindow
        case "control": self = .control
        case "intent": self = .intent
        case "watch": self = .watch
        case "command_line": self = .commandLine
        case "mcp": self = .mcp
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .app: "app"
        case .macPanel: "mac_panel"
        case .macWindow: "mac_window"
        case .control: "control"
        case .intent: "intent"
        case .watch: "watch"
        case .commandLine: "command_line"
        case .mcp: "mcp"
        case .unknown(let raw): raw
        }
    }

    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }
}
