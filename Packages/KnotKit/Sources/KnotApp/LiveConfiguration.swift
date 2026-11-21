import Foundation
import KnotCore

/// What an app shell's build says about itself, which the live composition needs before it
/// can resolve its `StoreLocations` (docs/architecture.md §7).
///
/// The shell's Info.plist carries the flavour, the app group, the Mac's development store
/// folder and the milestone level. `current()` reads them from the main bundle, with two
/// launch arguments that only a debug build honours: `-KnotPreview`, which selects
/// `.preview`, and `-KnotTemporaryStore <name>`, which roots the store in a folder of the
/// app's temporary folder named `<name>`, so that a UI test runs `.live` on a store of its own
/// and finds it again when it relaunches the app with the same name.
///
/// This type computes no store path: it gives `StoreLocations.resolve` the app's own folder
/// for its data, and `StoreLocations` alone says where the store sits inside it.
public struct LiveConfiguration: Sendable {
    #if DEBUG
        /// The launch argument that selects `.preview`. A release build holds neither argument.
        public static let previewArgument = "-KnotPreview"
        /// The launch argument, followed by a name, that roots `.live` in a temporary store of
        /// that name.
        public static let temporaryStoreArgument = "-KnotTemporaryStore"
    #endif

    public var flavour: StoreLocations.Flavour
    public var platform: StoreLocations.Platform
    /// The app's own folder for its data, such as Application Support.
    public var appContainer: URL
    public var appGroup: StoreLocations.AppGroup
    /// The Mac's development store folder, the worktree's ID.
    public var devStoreFolder: String?
    /// The process environment: `KNOT_AGENT=1` refuses the milestone store.
    public var environment: [String: String]
    /// The level of a milestone build, `nil` for a development build.
    public var milestoneLevel: MilestoneLevel?
    /// The named defaults suite of this device's settings, never the standard domain.
    public var settingsSuite: String
    /// What the diagnostics export says about the build.
    public var build: BuildInfo

    public init(
        flavour: StoreLocations.Flavour, platform: StoreLocations.Platform, appContainer: URL,
        appGroup: StoreLocations.AppGroup, devStoreFolder: String?, environment: [String: String],
        milestoneLevel: MilestoneLevel?, settingsSuite: String, build: BuildInfo
    ) {
        self.flavour = flavour
        self.platform = platform
        self.appContainer = appContainer
        self.appGroup = appGroup
        self.devStoreFolder = devStoreFolder
        self.environment = environment
        self.milestoneLevel = milestoneLevel
        self.settingsSuite = settingsSuite
        self.build = build
    }

    /// The configuration of this process, read from the main bundle and the launch arguments.
    public static func current() -> LiveConfiguration {
        let info = Bundle.main.infoDictionary ?? [:]
        func value(_ key: String) -> String? {
            guard let text = info[key] as? String, !text.isEmpty, !text.hasPrefix("$(") else { return nil }
            return text
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "knot"
        let flavour: StoreLocations.Flavour = value("KnotFlavour") == "milestone" ? .milestone : .dev
        // The build's configuration says whether it has an app group. The local signing
        // configuration of every agent, simulator and gate build carries neither the group nor
        // iCloud, and `KnotSyncAvailable` is `NO` there: both follow `KNOT_SIGNING`.
        let hasGroup = value("KnotSyncAvailable") == "YES"
        let appGroup: StoreLocations.AppGroup
        if hasGroup, let group = value("KnotAppGroup") {
            appGroup = .present(
                container: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group))
        } else {
            appGroup = hasGroup ? .present(container: nil) : .absent
        }
        var appContainer = URL.applicationSupportDirectory
        var settingsSuite = "\(bundleID).v1.device"
        #if DEBUG
            if let name = temporaryStoreName(in: ProcessInfo.processInfo.arguments) {
                appContainer = FileManager.default.temporaryDirectory
                    .appending(path: "KnotTemporaryStore", directoryHint: .isDirectory)
                    .appending(path: name, directoryHint: .isDirectory)
                settingsSuite = "\(bundleID).v1.temporary.\(name)"
            }
        #endif
        return LiveConfiguration(
            flavour: flavour, platform: .current, appContainer: appContainer, appGroup: appGroup,
            devStoreFolder: value("KnotDevStoreFolder"), environment: ProcessInfo.processInfo.environment,
            milestoneLevel: value("KnotMilestoneLevel").flatMap(MilestoneLevel.init(infoValue:)),
            settingsSuite: settingsSuite,
            build: BuildInfo(
                version: value("CFBundleShortVersionString") ?? "unversioned",
                build: value("CFBundleVersion") ?? "unknown", flavour: flavour,
                milestoneLevel: value("KnotMilestoneLevel").flatMap(MilestoneLevel.init(infoValue:))))
    }

    /// True when the launch arguments select `.preview`, which only a debug build honours.
    public static func selectsPreview(_ arguments: [String]) -> Bool {
        #if DEBUG
            arguments.contains(previewArgument)
        #else
            false
        #endif
    }

    #if DEBUG
        /// The name that follows `-KnotTemporaryStore`, when it is one path component of letters,
        /// digits, `.`, `_` and `-` that does not start with a dot, at most 64 characters.
        static func temporaryStoreName(in arguments: [String]) -> String? {
            guard let index = arguments.firstIndex(of: temporaryStoreArgument), index + 1 < arguments.count else {
                return nil
            }
            let name = arguments[index + 1]
            let allowed = name.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII
                    && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)
                        || "._-".unicodeScalars.contains(scalar))
            }
            guard allowed, !name.isEmpty, name.count <= 64, !name.hasPrefix(".") else { return nil }
            return name
        }
    #endif
}

/// The build, as the diagnostics export names it: no path, no account, no device name.
public struct BuildInfo: Hashable, Sendable, Codable {
    public var version: String
    public var build: String
    public var flavour: String
    /// `M1` to `M7`, or `none` for a development build.
    public var milestoneLevel: String

    public init(version: String, build: String, flavour: StoreLocations.Flavour, milestoneLevel: MilestoneLevel?) {
        self.version = version
        self.build = build
        self.flavour = flavour.rawValue
        self.milestoneLevel = milestoneLevel?.infoValue ?? "none"
    }
}
