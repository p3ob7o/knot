import Foundation
import SwiftUI

/// What VoiceOver says about a recording. It announces when a recording starts and stops, and
/// stays silent while it runs (docs/product-spec.md §13).
public enum Announcement: String, Hashable, Sendable, CaseIterable {
    case recordingStarted
    case recordingStopped
    /// A tap-started recording stopped within a second: nothing was kept.
    case recordingDiscarded
    case recordingCouldNotStart

    public var text: String {
        switch self {
        case .recordingStarted: localized("Recording")
        case .recordingStopped: localized("Saved")
        case .recordingDiscarded: localized("Too short. Nothing was kept.")
        case .recordingCouldNotStart: localized("Couldn’t start.")
        }
    }
}

/// Says an announcement. View models announce through it, so a test can hear what they say.
@MainActor
public protocol Announcer: AnyObject {
    func announce(_ announcement: Announcement)
}

/// Announces through VoiceOver. It never moves focus.
@MainActor
public final class VoiceOverAnnouncer: Announcer {
    public init() {}

    public func announce(_ announcement: Announcement) {
        AccessibilityNotification.Announcement(announcement.text).post()
    }
}

/// Keeps every announcement, for tests and previews.
@MainActor
public final class RecordingAnnouncer: Announcer {
    public private(set) var heard: [Announcement] = []

    public init() {}

    public func announce(_ announcement: Announcement) {
        heard.append(announcement)
    }
}
