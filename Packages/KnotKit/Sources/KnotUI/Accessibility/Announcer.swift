import Foundation
import SwiftUI

/// What VoiceOver says without moving focus. It announces the start and stop of a recording and
/// the outcome of a restore (docs/product-spec.md §13).
public enum Announcement: String, Hashable, Sendable, CaseIterable {
    case recordingStarted
    case recordingStopped
    case recordingSaveFailed
    /// A tap-started recording stopped within a second: nothing was kept.
    case recordingDiscarded
    case recordingCouldNotStart
    case itemRestored
    case itemRestoreFailed

    public var text: String {
        switch self {
        case .recordingStarted: localized("Recording")
        case .recordingStopped: localized("Saved")
        case .recordingSaveFailed: localized("Knot couldn’t finish saving the recording.")
        case .recordingDiscarded: localized("Too short. Nothing was kept.")
        case .recordingCouldNotStart: localized("Couldn’t start.")
        case .itemRestored: localized("Restored.")
        case .itemRestoreFailed: localized("Knot couldn’t restore this item.")
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
