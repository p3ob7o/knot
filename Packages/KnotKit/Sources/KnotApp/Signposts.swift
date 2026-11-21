import Foundation
import KnotCore
import Synchronization
import os

/// A moment that docs/product-spec.md §14 sets a target for, and the launch steps. Each has a
/// signpost, which Instruments and `scripts/verify.sh --perf` read, and its timings go into the
/// diagnostics export, so the milestone checklists record what the device measured.
///
/// The composition times the moments it sees: the launch steps, a typed save reaching disk, a
/// search, a note read. A moment that begins in a shell, such as a key release or an icon tap,
/// is timed by the shell through `SignpostTimings.begin(_:)`, and one that begins before Knot's
/// process exists is timed from outside it (§14).
public enum MeasuredMoment: String, Hashable, Sendable, Codable, CaseIterable {
    case macTapToTyping = "mac_tap_to_typing"
    case macHoldToLiveMicrophone = "mac_hold_to_live_microphone"
    case iPhoneIconToTypingWarm = "iphone_icon_to_typing_warm"
    case iPhoneIconToTypingCold = "iphone_icon_to_typing_cold"
    case iPhoneActionButtonToLiveMicrophone = "iphone_action_button_to_live_microphone"
    case watchComplicationToLiveMicrophoneWarm = "watch_complication_to_live_microphone_warm"
    case watchComplicationToLiveMicrophoneCold = "watch_complication_to_live_microphone_cold"
    case watchStopToTranscriptOnIPhone = "watch_stop_to_transcript_on_iphone"
    case typedTextOnDisk = "typed_text_on_disk"
    case audioLostOnKill = "audio_lost_on_kill"
    case transcriptReady = "transcript_ready"
    case searchResults = "search_results"
    case firstWriteDuringRestore = "first_write_during_restore"
    case inkOnDisk = "ink_on_disk"
    case noteOpened = "note_opened"
    case lostOnPowerCut = "lost_on_power_cut"
    case launchOpenStore = "launch_open_store"
    case launchRecovery = "launch_recovery"
    case launchResumeJobs = "launch_resume_jobs"
    case launchStartSync = "launch_start_sync"

    /// The signpost's name, which the system requires to be written in the code.
    var signpostName: StaticString {
        switch self {
        case .macTapToTyping: "mac_tap_to_typing"
        case .macHoldToLiveMicrophone: "mac_hold_to_live_microphone"
        case .iPhoneIconToTypingWarm: "iphone_icon_to_typing_warm"
        case .iPhoneIconToTypingCold: "iphone_icon_to_typing_cold"
        case .iPhoneActionButtonToLiveMicrophone: "iphone_action_button_to_live_microphone"
        case .watchComplicationToLiveMicrophoneWarm: "watch_complication_to_live_microphone_warm"
        case .watchComplicationToLiveMicrophoneCold: "watch_complication_to_live_microphone_cold"
        case .watchStopToTranscriptOnIPhone: "watch_stop_to_transcript_on_iphone"
        case .typedTextOnDisk: "typed_text_on_disk"
        case .audioLostOnKill: "audio_lost_on_kill"
        case .transcriptReady: "transcript_ready"
        case .searchResults: "search_results"
        case .firstWriteDuringRestore: "first_write_during_restore"
        case .inkOnDisk: "ink_on_disk"
        case .noteOpened: "note_opened"
        case .lostOnPowerCut: "lost_on_power_cut"
        case .launchOpenStore: "launch_open_store"
        case .launchRecovery: "launch_recovery"
        case .launchResumeJobs: "launch_resume_jobs"
        case .launchStartSync: "launch_start_sync"
        }
    }

    /// The moments of docs/product-spec.md §14, apart from the launch steps.
    public static let targets: [MeasuredMoment] = allCases.filter { !$0.rawValue.hasPrefix("launch_") }
}

/// The signposts of one process, and the durations they measured, which the diagnostics export
/// summarises. Only durations are kept: no ID, no text.
public final class SignpostTimings: Sendable {
    /// The most durations kept for one moment.
    public static let limit = 500

    private let signposter = OSSignposter(subsystem: "knot", category: "targets")
    private let durations = Mutex<[MeasuredMoment: [Duration]]>([:])
    private let clock = ContinuousClock()

    public init() {}

    /// Begins an interval of `moment`. Its `end()` records it once.
    public func begin(_ moment: MeasuredMoment) -> SignpostInterval {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(moment.signpostName, id: id)
        return SignpostInterval(timings: self, moment: moment, state: state, started: clock.now)
    }

    /// Records a duration measured elsewhere, such as from outside the process.
    public func record(_ moment: MeasuredMoment, _ duration: Duration) {
        durations.withLock { all in
            var list = all[moment, default: []]
            list.append(duration)
            if list.count > Self.limit { list.removeFirst(list.count - Self.limit) }
            all[moment] = list
        }
    }

    /// The durations measured for each moment, oldest first.
    public func snapshot() -> [MeasuredMoment: [Duration]] { durations.withLock { $0 } }

    fileprivate func end(_ interval: SignpostInterval) {
        signposter.endInterval(interval.moment.signpostName, interval.state)
        record(interval.moment, clock.now - interval.started)
    }
}

/// One interval of a signpost. Ending it twice records it once.
public final class SignpostInterval: Sendable {
    fileprivate let timings: SignpostTimings
    fileprivate let moment: MeasuredMoment
    fileprivate let state: OSSignpostIntervalState
    fileprivate let started: ContinuousClock.Instant
    private let ended = Mutex(false)

    fileprivate init(
        timings: SignpostTimings, moment: MeasuredMoment, state: OSSignpostIntervalState,
        started: ContinuousClock.Instant
    ) {
        self.timings = timings
        self.moment = moment
        self.state = state
        self.started = started
    }

    public func end() {
        let first = ended.withLock { ended -> Bool in
            defer { ended = true }
            return !ended
        }
        if first { timings.end(self) }
    }
}
