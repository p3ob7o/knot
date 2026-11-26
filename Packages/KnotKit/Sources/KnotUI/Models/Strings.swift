import Foundation
import KnotCore

/// A string of KnotUI's catalog (docs/product-spec.md §13: the interface is in English, and its
/// strings live in a catalog so that other languages can follow).
func localized(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}

/// How KnotUI writes a length of time: `0:42`, `12:05`, `1:02:03`.
public enum ClockText {
    public static func of(_ duration: Duration) -> String {
        let total = max(0, Int(duration.components.seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        let twoDigits = { (value: Int) in value < 10 ? "0\(value)" : "\(value)" }
        if hours > 0 { return "\(hours):\(twoDigits(minutes)):\(twoDigits(seconds))" }
        return "\(minutes):\(twoDigits(seconds))"
    }
}

extension VisibleState {
    /// The name a person reads, from KnotUI's catalog. The names are KnotCore's, so the app,
    /// the command line and the agent use the same words (docs/product-spec.md §5).
    public var label: String {
        switch self {
        case .savedOnWatch: localized("Saved on the Watch")
        case .savedTextOnItsWay: localized("Saved, text on its way")
        case .savedTextBeingMadeElsewhere: localized("Saved, text being made elsewhere")
        case .ready: localized("Ready")
        case .needsYou: localized("Needs you")
        case .keptNoText: localized("Kept, no text")
        case .madeByNewerKnot: localized("Made by a newer Knot. Update Knot to see it.")
        }
    }

    /// True while the segment's work is unfinished, which the pending marker shows.
    public var isPendingMark: Bool {
        self == .savedOnWatch || self == .savedTextOnItsWay || self == .savedTextBeingMadeElsewhere
    }
}

extension SegmentKind {
    /// What a segment of this kind holds, for a note that has no text yet: "Recording, 0:42" or
    /// "Sketch" (docs/product-spec.md §7).
    func holding(duration: Duration?) -> String {
        switch self {
        case .typed: localized("Text")
        case .voice:
            if let duration { localized("Recording, \(ClockText.of(duration))") } else { localized("Recording") }
        case .ink: localized("Sketch")
        case .unknown: localized("Made by a newer Knot")
        }
    }

    /// The kind's name, for the row's list of kinds and for VoiceOver.
    public var label: String {
        switch self {
        case .typed: localized("Typed")
        case .voice: localized("Recording")
        case .ink: localized("Sketch")
        case .unknown: localized("Unknown")
        }
    }
}

/// The append caption uses the region’s clock without a day period.
func appendCaptionTime(_ date: Date, calendar: Calendar, locale: Locale) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate("Jm")
    return formatter.string(from: date)
}
