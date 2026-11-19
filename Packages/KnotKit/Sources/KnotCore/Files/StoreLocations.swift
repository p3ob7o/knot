import Foundation

/// The one place that computes where Knot's files live (docs/architecture.md §3 and §7).
///
/// Everything v1 writes sits in a folder named `KnotStore/`, in the app's container and in
/// the app group. The retired app owns `Application Support/Knot/` in the same container,
/// and v1 never opens, lists, moves or deletes it. No library target has a default path: the
/// app shell or the tool passes its flavour and containers in, and a test passes a folder.
/// A file's place comes from its ID, never from a name in a manifest or a record.
public struct StoreLocations: Hashable, Sendable {
    /// The build flavour. Only a milestone build opens the milestone store.
    public enum Flavour: String, Hashable, Sendable {
        case dev
        case milestone
    }

    public enum Platform: Hashable, Sendable {
        case iOS
        case macOS
        case watchOS

        /// The platform this code runs on.
        public static var current: Platform {
            #if os(macOS)
                .macOS
            #elseif os(watchOS)
                .watchOS
            #else
                .iOS
            #endif
        }
    }

    /// Whether the build has an app group, which its configuration says: the local signing
    /// configuration, used by every agent, simulator and gate build, has none.
    public enum AppGroup: Hashable, Sendable {
        /// The build has an app group. `container` is what the system gave, `nil` when it
        /// gave none, which is refused.
        case present(container: URL?)
        /// The build has no app group. What would sit in it stays in the app's own container.
        case absent
    }

    /// The name of the folder that roots everything v1 writes.
    public static let rootFolderName = "KnotStore"

    /// The folder that holds the database and the stored assets.
    public let storeRoot: URL
    /// The folder that holds `Inbox/` and the recording state: the app group on iOS and on the
    /// Watch, so that the watch link and the widget extensions reach them.
    public let sharedRoot: URL
    /// False when the build has no app group, so that what depends on one is switched off:
    /// the `knot-dev` tool cannot open the store, and the extensions see no recording state.
    public let hasAppGroup: Bool

    public var database: URL { storeRoot.appending(path: "knot.sqlite", directoryHint: .notDirectory) }
    public var assets: URL { storeRoot.appending(path: "Assets", directoryHint: .isDirectory) }
    /// Audio in progress and its manifests. In the store's folder, because a recording runs
    /// in the app process.
    public var recording: URL { storeRoot.appending(path: "Recording", directoryHint: .isDirectory) }
    /// Items waiting to be ingested.
    public var inbox: URL { sharedRoot.appending(path: "Inbox", directoryHint: .isDirectory) }
    /// The saved recording state that controls and widgets in other processes read.
    public var recordingState: URL { sharedRoot.appending(path: "RecordingState", directoryHint: .isDirectory) }
    /// The watch's outbox: recordings that wait for the iPhone's acknowledgement.
    public var outbox: URL { storeRoot.appending(path: "Outbox", directoryHint: .isDirectory) }

    private init(storeRoot: URL, sharedRoot: URL, hasAppGroup: Bool) {
        self.storeRoot = storeRoot
        self.sharedRoot = sharedRoot
        self.hasAppGroup = hasAppGroup
    }

    /// The locations of a store that `root` holds whole, as package tests use: they are not
    /// sandboxed and pass a folder under the worktree.
    public static func testing(root: URL) -> StoreLocations {
        let store = root.appending(path: rootFolderName, directoryHint: .isDirectory)
        return StoreLocations(storeRoot: store, sharedRoot: store, hasAppGroup: false)
    }

    /// The locations for an app shell or the tool.
    ///
    /// - Parameters:
    ///   - flavour: the build's flavour, from its Info.plist.
    ///   - platform: where the code runs.
    ///   - appContainer: the app's own folder for its data, such as Application Support.
    ///   - appGroup: whether the build has an app group, from its configuration, and if so
    ///     the container the system gave. `StoreLocations` never guesses it from a missing
    ///     container: a build that has a group and got no container is refused. A build with
    ///     no group keeps in the app's own container, in the same `KnotStore/` layout, what
    ///     would sit in the group.
    ///   - devStoreFolder: on the Mac, the worktree's folder in the development container,
    ///     which only debug builds honour. A development build on the Mac must name one, or it
    ///     is refused with `dev_store_folder_invalid`: development builds from two worktrees
    ///     never share a store. A milestone build ignores it.
    ///   - environment: the process environment. With `KNOT_AGENT=1`, the milestone store
    ///     is refused, so an agent cannot open the owner's notes by accident.
    public static func resolve(
        flavour: Flavour, platform: Platform, appContainer: URL, appGroup: AppGroup, devStoreFolder: String? = nil,
        environment: [String: String]
    ) throws(KnotError) -> StoreLocations {
        if flavour == .milestone, environment["KNOT_AGENT"] == "1" { throw KnotError.agentRefusedMilestoneStore }
        let groupContainer: URL?
        switch appGroup {
        case .present(let container):
            guard let container else { throw KnotError.groupContainerMissing }
            groupContainer = container
        case .absent:
            groupContainer = nil
        }
        let hasGroup = groupContainer != nil
        let ownRoot = appContainer.appending(path: rootFolderName, directoryHint: .isDirectory)
        let groupRoot = groupContainer?.appending(path: rootFolderName, directoryHint: .isDirectory)
        switch platform {
        case .watchOS:
            // The Watch has no database. Its recording state sits in the group, which the
            // Watch app shares with its widget extension for the complication; its recordings
            // and its outbox stay in its own container.
            return StoreLocations(storeRoot: ownRoot, sharedRoot: groupRoot ?? ownRoot, hasAppGroup: hasGroup)
        case .iOS:
            // The database stays in the app's own container: iOS kills a process suspended
            // while it holds a lock on a database in a shared container.
            return StoreLocations(storeRoot: ownRoot, sharedRoot: groupRoot ?? ownRoot, hasAppGroup: hasGroup)
        case .macOS:
            // In the app group, so that the `knot` command opens the same store; without one,
            // in the app's own container, which the tool cannot open.
            var base = groupContainer ?? appContainer
            if flavour == .dev {
                // Development builds from two worktrees never share a store, so a build that
                // names no usable worktree folder is refused, never given a shared one.
                guard let folder = devStoreFolder, let name = safeFolderName(folder) else {
                    throw KnotError.devStoreFolderInvalid
                }
                base = base.appending(path: name, directoryHint: .isDirectory)
            }
            let root = base.appending(path: rootFolderName, directoryHint: .isDirectory)
            return StoreLocations(storeRoot: root, sharedRoot: root, hasAppGroup: hasGroup)
        }
    }

    /// The stored file of an asset: `Assets/<last two ID characters>/<assetID>.<ext>`.
    public func asset(_ id: AssetID, kind: AssetKind) -> URL {
        assets.appending(path: id.folderName, directoryHint: .isDirectory)
            .appending(path: "\(id).\(kind.fileExtension)", directoryHint: .notDirectory)
    }

    /// The manifest of an item in `Inbox/`.
    public func inboxManifest(_ capture: CaptureID) -> URL {
        inbox.appending(path: "\(capture).json", directoryHint: .notDirectory)
    }

    /// The payload of an item in `Inbox/`: the text, the recording or the drawing.
    public func inboxPayload(_ capture: CaptureID, kind: SegmentKind) -> URL {
        inbox.appending(path: "\(capture).\(Self.payloadExtension(kind))", directoryHint: .notDirectory)
    }

    /// The manifest of a recording in progress, written before the first audio sample.
    public func recordingManifest(_ capture: CaptureID) -> URL {
        recording.appending(path: "\(capture).json", directoryHint: .notDirectory)
    }

    /// The working audio file of a recording in progress.
    public func recordingAudio(_ capture: CaptureID, format: RecordingFormat) -> URL {
        recording.appending(path: "\(capture).\(format.fileExtension)", directoryHint: .notDirectory)
    }

    /// The manifest of a recording in the watch's outbox.
    public func outboxManifest(_ capture: CaptureID) -> URL {
        outbox.appending(path: "\(capture).json", directoryHint: .notDirectory)
    }

    /// The recording in the watch's outbox.
    public func outboxAudio(_ capture: CaptureID) -> URL {
        outbox.appending(path: "\(capture).\(AssetKind.audio.fileExtension)", directoryHint: .notDirectory)
    }

    private static func payloadExtension(_ kind: SegmentKind) -> String {
        switch kind {
        case .typed: "txt"
        case .voice: AssetKind.audio.fileExtension
        case .ink: AssetKind.ink.fileExtension
        case .unknown: "bin"
        }
    }

    /// A worktree's folder name, as one path component: letters, digits, `.`, `_` and `-`,
    /// not starting with a dot, at most 128 characters. Any other name is refused.
    private static func safeFolderName(_ name: String) -> String? {
        let allowed = name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII
                && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)
                    || "._-".unicodeScalars.contains(scalar))
        }
        guard allowed, !name.isEmpty, name.count <= 128, !name.hasPrefix(".") else { return nil }
        return name
    }
}

/// The formats a recording in progress may be written in (docs/architecture.md §8). WP-12
/// picks one of the two candidates and proves it with a kill test. A closed set, so that no
/// text from outside becomes part of a path.
public enum RecordingFormat: String, Hashable, Sendable, CaseIterable {
    /// Core Audio Format.
    case caf
    /// Fragmented MPEG-4.
    case fragmentedMP4 = "fragmented_mp4"

    public var fileExtension: String {
        switch self {
        case .caf: "caf"
        case .fragmentedMP4: "mp4"
        }
    }
}
