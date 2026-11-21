import Foundation
import KnotCore

/// What the view models need to know about the device and the build that no port tells them.
/// The composition fills it in: KnotApp for the apps, KnotUIPreviews for the previews.
public struct UIContext: Sendable {
    /// This device's ID, which decides whether a recording's work is made here or elsewhere
    /// (`VisibleState.of`).
    public var thisDevice: DeviceID
    /// Whether this build can sync at all.
    public var sync: SyncAvailability

    public init(thisDevice: DeviceID, sync: SyncAvailability) {
        self.thisDevice = thisDevice
        self.sync = sync
    }
}

/// Whether sync can run in this build (docs/plan/WP-21.md, the first-run stream).
public enum SyncAvailability: Hashable, Sendable {
    /// The build cannot sync: the local configuration of an agent or a test, or a milestone
    /// build below M4.
    case notInThisBuild
    /// The build can sync. Whether the device is signed in to iCloud decides the default of
    /// the switch (docs/product-spec.md §9).
    case available(signedInToICloud: Bool)
}

/// What the first-run stream says about sync. It follows the sync state the build really has
/// (docs/plan/WP-21.md).
public enum FirstRunSync: Hashable, Sendable {
    /// Sync is on: the empty stream says so, and where its switch is (docs/product-spec.md §12).
    case on
    /// The person switched sync off. The line for this case is the owner's wording, the open
    /// point "The first-run line when sync is switched off" of docs/plan/open-points.md. Until he
    /// gives it, the stream shows no line about sync.
    case offByPerson
    /// Sync is not available in this build, or not on this device because it is signed out of
    /// iCloud and the person never chose. The stream says nothing about sync.
    case notAvailable

    /// The case for a build, the person's settings and the gates.
    public static func resolve(sync: SyncAvailability, settings: Settings, gates: any FeatureGates) -> FirstRunSync {
        guard case .available(let signedIn) = sync, gates.isOpen(.sync) else { return .notAvailable }
        switch settings.syncEnabled {
        case false?: return .offByPerson
        case true?: return .on
        case nil: return signedIn ? .on : .notAvailable
        }
    }

    /// The line the empty stream shows, or `nil` for none.
    public var line: String? {
        switch self {
        case .on: localized("Sync is on. You can turn it off in Settings.")
        case .offByPerson, .notAvailable: nil
        }
    }
}

/// A dismissible row of the first-run stream on setting up a way to capture (assumption A29).
/// There are at most three, and the app shell says which apply on its device.
public enum SetupRow: String, Hashable, Sendable, CaseIterable, Identifiable {
    case actionButton = "action_button"
    case lockScreenControl = "lock_screen_control"
    case watchComplication = "watch_complication"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .actionButton: localized("Record with the Action Button")
        case .lockScreenControl: localized("Add a Lock Screen control")
        case .watchComplication: localized("Add the Watch complication")
        }
    }
}
