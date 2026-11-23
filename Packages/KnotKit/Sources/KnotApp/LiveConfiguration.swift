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
    /// Why this build has no store place whatever `StoreLocations` would say: a temporary store
    /// was asked for with a name that is refused. Such a build gets no store, never the default
    /// one, where a UI test would then write.
    public var refusal: KnotError?

    public init(
        flavour: StoreLocations.Flavour, platform: StoreLocations.Platform, appContainer: URL,
        appGroup: StoreLocations.AppGroup, devStoreFolder: String?, environment: [String: String],
        milestoneLevel: MilestoneLevel?, settingsSuite: String, build: BuildInfo, refusal: KnotError? = nil
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
        self.refusal = refusal
    }

    /// The configuration of this process, read from the main bundle and the launch arguments.
    public static func current() -> LiveConfiguration {
        current(
            info: Bundle.main.infoDictionary ?? [:], bundleID: Bundle.main.bundleIdentifier ?? "knot",
            arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)
    }

    /// The configuration a build with this Info.plist, bundle ID, launch arguments and
    /// environment reads: `current()` gives it this process's, and the composition's smoke test
    /// gives it a temporary store's launch arguments, as a UI test launches the app with them.
    static func current(
        info: [String: Any], bundleID: String, arguments: [String], environment: [String: String]
    ) -> LiveConfiguration {
        func value(_ key: String) -> String? {
            guard let text = info[key] as? String, !text.isEmpty, !text.hasPrefix("$(") else { return nil }
            return text
        }
        let flavour = flavour(info: info)
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
        var refusal: KnotError?
        switch LaunchArguments.read(arguments, flavour: flavour).temporaryStore {
        case .none:
            break
        case .named(let name):
            appContainer = FileManager.default.temporaryDirectory
                .appending(path: "KnotTemporaryStore", directoryHint: .isDirectory)
                .appending(path: name, directoryHint: .isDirectory)
            settingsSuite = "\(bundleID).v1.temporary.\(name)"
        case .refused:
            refusal = .devStoreFolderInvalid
        }
        return LiveConfiguration(
            flavour: flavour, platform: .current, appContainer: appContainer, appGroup: appGroup,
            devStoreFolder: value("KnotDevStoreFolder"), environment: environment,
            milestoneLevel: value("KnotMilestoneLevel").flatMap(MilestoneLevel.init(infoValue:)),
            settingsSuite: settingsSuite,
            build: BuildInfo(
                version: value("CFBundleShortVersionString") ?? "unversioned",
                build: value("CFBundleVersion") ?? "unknown", flavour: flavour,
                milestoneLevel: value("KnotMilestoneLevel").flatMap(MilestoneLevel.init(infoValue:))),
            refusal: refusal)
    }

    /// The flavour the main bundle's Info.plist names: `milestone`, or `dev` for anything else.
    public static func currentFlavour() -> StoreLocations.Flavour {
        flavour(info: Bundle.main.infoDictionary ?? [:])
    }

    /// The flavour an Info.plist names.
    static func flavour(info: [String: Any]) -> StoreLocations.Flavour {
        (info["KnotFlavour"] as? String) == "milestone" ? .milestone : .dev
    }

    /// True when the launch arguments select `.preview`: only in a debug build that is not a
    /// milestone build.
    public static func selectsPreview(_ arguments: [String], flavour: StoreLocations.Flavour) -> Bool {
        LaunchArguments.read(arguments, flavour: flavour).preview
    }
}

/// What a build makes of its launch arguments. Only a debug build honours them, and a milestone
/// build never does, whatever its configuration.
public struct LaunchArguments: Hashable, Sendable {
    public enum TemporaryStore: Hashable, Sendable {
        case none
        case named(String)
        /// Asked for with a name that is not one path component of letters, digits, `.`, `_`
        /// and `-`, at most 64 characters, not starting with a dot or a dash, or with no name at all.
        case refused
    }

    public var preview: Bool
    public var temporaryStore: TemporaryStore

    public static func read(_ arguments: [String], flavour: StoreLocations.Flavour) -> LaunchArguments {
        #if DEBUG
            guard flavour != .milestone else { return LaunchArguments(preview: false, temporaryStore: .none) }
            var temporaryStore = TemporaryStore.none
            if let index = arguments.firstIndex(of: LiveConfiguration.temporaryStoreArgument) {
                if index + 1 < arguments.count, let name = Self.accepted(arguments[index + 1]) {
                    temporaryStore = .named(name)
                } else {
                    temporaryStore = .refused
                }
            }
            return LaunchArguments(
                preview: arguments.contains(LiveConfiguration.previewArgument), temporaryStore: temporaryStore)
        #else
            return LaunchArguments(preview: false, temporaryStore: .none)
        #endif
    }

    #if DEBUG
        private static func accepted(_ name: String) -> String? {
            let allowed = name.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII
                    && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)
                        || "._-".unicodeScalars.contains(scalar))
            }
            guard allowed, !name.isEmpty, name.count <= 64, !name.hasPrefix("."), !name.hasPrefix("-") else {
                return nil
            }
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
