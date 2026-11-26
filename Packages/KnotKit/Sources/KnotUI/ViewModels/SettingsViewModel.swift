import Foundation
import KnotCore
import Observation

/// Which device the settings are for: the list differs (docs/product-spec.md §11).
public enum SettingsPlatform: String, Hashable, Sendable, CaseIterable {
    case iPhone
    case iPad
    case mac
}

/// A row of Settings. This is the complete list (docs/product-spec.md §11).
public enum SettingsRow: String, Hashable, Sendable, CaseIterable, Identifiable {
    case appendWindow
    case cleanup
    case englishVariant
    case sync
    case hotkey
    case launchAtLogin
    case commandLineAccess
    case exportAll
    case recentlyDeleted
    case about

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .appendWindow: localized("Append window")
        case .cleanup: localized("Clean up transcripts")
        case .englishVariant: localized("English variant")
        case .sync: localized("iCloud sync")
        case .hotkey: localized("Hotkey")
        case .launchAtLogin: localized("Launch at login")
        case .commandLineAccess: localized("Command-line access")
        case .exportAll: localized("Export all notes")
        case .recentlyDeleted: localized("Recently deleted")
        case .about: localized("About")
        }
    }
}

/// The status the iCloud sync row can show, without exposing CloudKit errors.
public enum SettingsSyncState: Hashable, Sendable, CaseIterable {
    case off
    case upToDate
    case syncing
    case error
    case storageFull
    case noAccount

    public init(_ status: SyncStatus) {
        switch status {
        case .off: self = .off
        case .idle: self = .upToDate
        case .fetching, .sending: self = .syncing
        case .failed(KnotError.syncQuotaExceeded.code): self = .storageFull
        case .failed(KnotError.syncSignedOut.code): self = .noAccount
        case .failed, .paused, .waiting: self = .error
        }
    }

    public var label: String {
        switch self {
        case .off: localized("Off")
        case .upToDate: localized("Up to date")
        case .syncing: localized("Syncing…")
        case .error: localized("Sync paused. Your notes are kept on this device.")
        case .storageFull: localized("iCloud storage is full. Your notes and recordings are kept on this device.")
        case .noAccount: localized("Sign in to iCloud to sync your notes.")
        }
    }
}

/// Settings (docs/product-spec.md §11 and §12).
@MainActor
@Observable
public final class SettingsViewModel {
    public private(set) var settings: Settings = .defaults
    /// False when the settings cannot be read: the rows show the defaults and do not change.
    public private(set) var isAvailable = false
    /// Why cleanup cannot run on this device, which its row says, or `nil` when it can.
    public private(set) var cleanupNote: String?
    public private(set) var saveProblem: ErrorCode?
    /// Whether the person may turn sync on here: the build can sync and its gate is open.
    public private(set) var offersSync = false
    public private(set) var syncState: SettingsSyncState = .off

    public let platform: SettingsPlatform
    private let environment: AppEnvironment
    private let context: UIContext
    private let liveActivitiesEnabled: Bool?

    /// - Parameter liveActivitiesEnabled: on iPhone and iPad, whether Live Activities are on,
    ///   which the app shell reads from ActivityKit; `nil` where it does not apply.
    public init(
        environment: AppEnvironment, context: UIContext, platform: SettingsPlatform, liveActivitiesEnabled: Bool? = nil
    ) {
        self.environment = environment
        self.context = context
        self.platform = platform
        self.liveActivitiesEnabled = liveActivitiesEnabled
    }

    /// The rows on this device, in order.
    public var rows: [SettingsRow] {
        var rows: [SettingsRow] = [.appendWindow, .cleanup, .englishVariant]
        if offersSync { rows.append(.sync) }
        if platform == .mac { rows += [.hotkey, .launchAtLogin, .commandLineAccess] }
        rows += [.exportAll, .recentlyDeleted, .about]
        return rows
    }

    /// If Live Activities are off, Settings says that recording from the Lock Screen will open
    /// Knot instead (docs/product-spec.md §12).
    public var lockScreenNote: String? {
        guard platform != .mac, liveActivitiesEnabled == false else { return nil }
        return localized("Live Activities are off, so recording from the Lock Screen opens Knot first.")
    }

    /// The append window, said in words.
    public var appendWindowText: String {
        let minutes = settings.appendWindow.minutes
        if minutes == 0 { return localized("Off: every capture is its own note") }
        return minutes == 1 ? localized("1 minute") : localized("\(minutes) minutes")
    }

    /// The choices the English variant offers. The device's region comes first.
    public static let englishVariants: [EnglishVariant] = [
        .followRegion, .locale("en_US"), .locale("en_GB"), .locale("en_AU"), .locale("en_CA"), .locale("en_IE"),
        .locale("en_IN"), .locale("en_NZ"), .locale("en_ZA"),
    ]

    public static func label(of variant: EnglishVariant) -> String {
        switch variant {
        case .followRegion: return localized("Follow the region")
        case .locale(let identifier):
            return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
        case .unknown(let raw): return raw
        }
    }

    /// The Mac hotkey, said in words, or that none is chosen yet.
    public var hotkeyText: String {
        guard let hotkey = settings.hotkey else { return localized("Not chosen") }
        var text = ""
        if hotkey.modifiers.contains(.control) { text += "⌃" }
        if hotkey.modifiers.contains(.option) { text += "⌥" }
        if hotkey.modifiers.contains(.shift) { text += "⇧" }
        if hotkey.modifiers.contains(.command) { text += "⌘" }
        return text + localized("Key \(Int(hotkey.keyCode))")
    }

    public func load() async {
        do {
            settings = try await environment.settings.load()
            isAvailable = true
        } catch {
            settings = .defaults
            isAvailable = false
        }
        offersSync = context.sync != .notInThisBuild && environment.gates.isOpen(.sync)
        cleanupNote =
            switch await environment.cleaner.availability() {
            case .available: nil
            case .notReady: localized("The cleanup model is still downloading.")
            case .unavailable(.deviceNotEligible): localized("This device can't clean up transcripts.")
            case .unavailable(.appleIntelligenceOff): localized("Turn on Apple Intelligence to clean up transcripts.")
            case .unavailable(.unsupportedLanguage): localized("Cleanup doesn't support this language.")
            case .unavailable: localized("Cleanup isn't available on this device.")
            }
    }

    /// Follows changes from sync and from other surfaces.
    public func observeChanges() async {
        for await changed in environment.settings.changes() {
            settings = changed
        }
    }

    public func observeSync() async {
        guard context.sync != .notInThisBuild else { return }
        for await status in environment.sync.statusUpdates() {
            syncState = SettingsSyncState(status)
        }
    }

    public func setAppendWindow(minutes: Int) async {
        guard let window = try? AppendWindow(minutes: minutes) else { return }
        await change { $0.appendWindow = window }
    }

    public func setCleanupEnabled(_ enabled: Bool) async {
        await change { $0.cleanupEnabled = enabled }
    }

    public func setEnglishVariant(_ variant: EnglishVariant) async {
        await change { $0.englishVariant = variant }
    }

    public func setSyncEnabled(_ enabled: Bool) async {
        guard offersSync else { return }
        await change { $0.syncEnabled = enabled }
    }

    public func setLaunchAtLogin(_ enabled: Bool) async {
        guard platform == .mac else { return }
        await change { $0.launchAtLogin = enabled }
    }

    public func setCommandLineAccess(_ enabled: Bool) async {
        guard platform == .mac else { return }
        await change { $0.commandLineAccess = enabled }
    }

    /// Saves a change whole. A save that fails leaves the settings as they were, and says so.
    private func change(_ edit: (inout Settings) -> Void) async {
        guard isAvailable else { return }
        var next = settings
        edit(&next)
        guard next != settings else { return }
        do {
            try await environment.settings.save(next)
            settings = next
            saveProblem = nil
        } catch {
            saveProblem = error.code
        }
    }
}
