import Foundation

/// How a launch of the Watch app composes itself, read from its launch arguments.
///
/// A release build always runs live: it ignores every argument here. A debug build honours
/// them, so that a UI test can run the app on the preview environment, or run the real
/// recorder, coordinator and outbox on injected audio and a temporary store, since a simulator
/// refuses the microphone (docs/architecture.md §8). The UI test target compiles this file
/// too, and its tests show that a release build ignores the arguments.
enum WatchLaunch: Equatable, Sendable {
    /// The real composition, on the microphone and the Watch's own folders.
    case live
    /// The real composition on injected audio and a temporary store. Debug builds only.
    case injectedAudio
    /// The preview environment: the scripted recorder and the fake link. Debug builds only.
    case preview(WatchPreview)

    /// Selects `.preview`.
    static let previewArgument = "-KnotPreview"
    /// Selects `.injectedAudio`.
    static let injectedAudioArgument = "-KnotInjectedAudio"
    /// With `.preview`: the first start fails, as when the microphone is refused.
    static let startFailsArgument = "-KnotPreviewStartFails"
    /// With `.preview`: each recording reaches the 30-minute limit by itself, at once.
    static let endsAtLimitArgument = "-KnotPreviewEndsAtLimit"
    /// With `.preview`: the first recording reaches its limit by itself, and its conversion
    /// waits until the next recording is live, as a long recording's does.
    static let holdsFirstConversionArgument = "-KnotPreviewHoldsFirstConversion"
    /// With `.preview`, followed by a number of seconds: each press is dated that long after
    /// the one before, so that a test of the one-second rule rests on no time of its own.
    static let pressGapArgument = "-KnotPreviewPressGap"

    /// The launch that `arguments` ask for. Without `honoursDebugArguments`, as in a release
    /// build, it is always `.live`.
    static func mode(arguments: [String], honoursDebugArguments: Bool) -> WatchLaunch {
        guard honoursDebugArguments else { return .live }
        if arguments.contains(injectedAudioArgument) { return .injectedAudio }
        guard arguments.contains(previewArgument) else { return .live }
        var preview = WatchPreview()
        preview.startFails = arguments.contains(startFailsArgument)
        preview.endsAtLimit = arguments.contains(endsAtLimitArgument)
        preview.holdsFirstConversion = arguments.contains(holdsFirstConversionArgument)
        if let index = arguments.firstIndex(of: pressGapArgument), arguments.indices.contains(index + 1),
            let gap = Double(arguments[index + 1]), gap.isFinite, gap >= 0
        {
            preview.pressGap = gap
        }
        return .preview(preview)
    }

    /// True in a debug build, which alone honours the arguments.
    static var isDebugBuild: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    /// This process's launch.
    static var current: WatchLaunch {
        mode(arguments: ProcessInfo.processInfo.arguments, honoursDebugArguments: isDebugBuild)
    }
}

/// What a preview launch scripts.
struct WatchPreview: Equatable, Sendable {
    var startFails = false
    /// Each recording ends by itself at the limit, as soon as it is live.
    var endsAtLimit = false
    /// The first recording ends by itself at its limit, and its conversion waits until the next
    /// recording is live.
    var holdsFirstConversion = false
    /// Seconds between the dates of two presses, or `nil` for the clock's own time.
    var pressGap: Double?
}
