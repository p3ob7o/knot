import Foundation
import KnotCore
import KnotLink
import KnotUI
import Observation

/// What the record screen says under its control. Every outcome of a press has words, and so
/// has a recording that stopped by itself. Nothing implies that Knot is recording until the
/// recording is live (docs/product-spec.md §4.5).
enum RecordStatus: Equatable, Sendable {
    /// Nothing to say: the app has just opened, or a press is starting a recording.
    case ready
    /// The recording is live.
    case recording
    /// The recording stopped at a press, and this became of it.
    case stopped(RecordFate)
    /// A tap-started recording stopped within a second: nothing was kept.
    case tooShort
    /// The recording could not start, for this reason.
    case couldNotStart(RecordFailure)
    /// The recording stopped by itself, for this reason, and this became of it.
    case stoppedEarly(EarlyStop, RecordFate)

    /// The words on the screen, or `nil` for none.
    var text: String? {
        switch self {
        case .ready: nil
        case .recording: String(localized: "Recording")
        case .stopped(let fate): fate.text
        case .tooShort: String(localized: "Too short. Nothing was kept.")
        case .couldNotStart(let failure): String(localized: "Couldn't start recording. \(failure.text)")
        case .stoppedEarly(let reason, let fate): String(localized: "Recording stopped. \(reason.text) \(fate.text)")
        }
    }
}

/// What became of a recording that stopped.
enum RecordFate: Equatable, Sendable {
    /// Kept on the Watch, to be sent to the iPhone.
    case saved
    /// Kept on the Watch, but a step failed for good, so it cannot be sent.
    case savedNotSendable
    /// It held no audio, so nothing is kept.
    case nothingRecorded

    init(_ outcome: WatchCoordinator.StopOutcome) {
        switch outcome {
        case .sent, .acknowledged: self = .saved
        case .kept(_, let error): self = error.isFinal ? .savedNotSendable : .saved
        case .endedWithoutAudio: self = .nothingRecorded
        }
    }

    var text: String {
        switch self {
        case .saved: String(localized: "Saved")
        case .savedNotSendable: String(localized: "Saved on this Watch. It can't be sent to the iPhone.")
        case .nothingRecorded: String(localized: "Nothing was kept.")
        }
    }

    /// What VoiceOver says of it.
    var announcement: Announcement { self == .nothingRecorded ? .recordingDiscarded : .recordingStopped }
}

/// Why a recording stopped by itself (docs/product-spec.md §4.2 and §4.4).
enum EarlyStop: Equatable, Sendable {
    case limitReached
    case interrupted
    case inputLost
    case diskFull
    case writeFailed
    case other

    init(_ ending: RecordingEnding) {
        switch ending {
        case .limitReached: self = .limitReached
        case .interrupted: self = .interrupted
        case .inputLost: self = .inputLost
        case .diskFull: self = .diskFull
        case .writeFailed: self = .writeFailed
        case .stopped, .recovered, .discarded: self = .other
        }
    }

    var text: String {
        switch self {
        case .limitReached: String(localized: "It reached the 30-minute limit.")
        case .interrupted: String(localized: "A call or another app took the microphone.")
        case .inputLost: String(localized: "The microphone went away.")
        case .diskFull: String(localized: "This Watch is full.")
        case .writeFailed: String(localized: "It couldn't be written further.")
        case .other: String(localized: "It ended.")
        }
    }
}

/// Why a recording could not start, in words a person can act on, from the error's next action.
enum RecordFailure: Equatable, Sendable {
    case microphoneRefused
    case noMicrophone
    case microphoneBusy
    case tooLittleSpace
    /// The app could not set itself up to record.
    case notReady
    case other

    init(_ error: KnotError) {
        switch error.next {
        case .allowMicrophone: self = .microphoneRefused
        case .connectMicrophone: self = .noMicrophone
        case .waitAndRetry: self = .microphoneBusy
        case .freeSpace: self = .tooLittleSpace
        default: self = .other
        }
    }

    var text: String {
        switch self {
        case .microphoneRefused: String(localized: "Allow the microphone for Knot in Settings.")
        case .noMicrophone: String(localized: "No microphone is available.")
        case .microphoneBusy: String(localized: "The microphone is busy. Try again in a moment.")
        case .tooLittleSpace: String(localized: "There isn't enough space on this Watch.")
        case .notReady: String(localized: "Knot can't record on this Watch right now.")
        case .other: String(localized: "Try again.")
        }
    }
}

/// The record screen's behaviour. A press goes to the coordinator, which applies the press
/// rule (docs/product-spec.md §4.2), and to nothing else: the model only says what came of it.
@MainActor
@Observable
final class RecordScreenModel {
    /// Where the record control stands.
    private(set) var phase: KnotUI.RecordingPhase = .idle
    private(set) var status: RecordStatus = .ready

    @ObservationIgnored private let composition: WatchComposition
    @ObservationIgnored private let announcer: any Announcer
    @ObservationIgnored private var launched = false
    /// The recordings that ended by themselves, so that a start reported after its own end
    /// does not show the control as recording.
    @ObservationIgnored private var endedByThemselves: Set<CaptureID> = []

    /// Subscribes to the coordinator's endings at once, before launch and before the first
    /// press, since a listener hears only what ends after it subscribes.
    init(composition: WatchComposition, announcer: any Announcer = VoiceOverAnnouncer()) {
        self.composition = composition
        self.announcer = announcer
        if let endings = composition.coordinator?.endings() {
            Task { [weak self] in
                for await ended in endings {
                    self?.ended(ended)
                }
            }
        }
    }

    /// The record control's phase as the control shows it. While a recording starts it shows
    /// as idle, so that nothing implies that Knot records before the recording is live; the
    /// control is disabled meanwhile.
    var controlPhase: KnotUI.RecordingPhase { phase == .starting ? .idle : phase }

    /// True while the control takes no press.
    var controlDisabled: Bool { phase == .starting || phase == .stopping }

    /// Finishes what earlier launches left, without holding up presses: the coordinator takes
    /// presses while it does (`WatchCoordinator.launch()`). Called once.
    func launch() {
        guard !launched, let coordinator = composition.coordinator else { return }
        launched = true
        Task { await coordinator.launch() }
    }

    /// A press of the record control. Its date is taken now, as the press rule measures the
    /// second between two presses.
    func press() {
        let press = Press(.tap, at: composition.pressClock.now())
        guard let coordinator = composition.coordinator else {
            status = .couldNotStart(.notReady)
            announcer.announce(.recordingCouldNotStart)
            return
        }
        let before = phase
        switch phase {
        case .idle:
            phase = .starting
            status = .ready
        case .recording:
            phase = .stopping
        case .starting, .stopping:
            break
        }
        let moved = phase != before
        Task {
            let outcome = await coordinator.press(press)
            await apply(outcome, from: coordinator, before: moved ? before : nil)
        }
    }

    /// Says what came of a press. `before` is the phase the press moved the control from, if it
    /// moved it.
    private func apply(
        _ outcome: WatchCoordinator.PressOutcome, from coordinator: WatchCoordinator, before: KnotUI.RecordingPhase?
    ) async {
        switch outcome {
        case .started(let capture):
            // It may have ended by itself already, and said so.
            guard !endedByThemselves.contains(capture) else { return }
            phase = .recording(capture)
            status = .recording
            announcer.announce(.recordingStarted)
        case .stopped(let stop):
            let fate = RecordFate(stop)
            phase = .idle
            status = .stopped(fate)
            announcer.announce(fate.announcement)
        case .discarded:
            phase = .idle
            status = .tooShort
            announcer.announce(.recordingDiscarded)
        case .failedToStart(let error):
            phase = .idle
            status = .couldNotStart(RecordFailure(error))
            announcer.announce(.recordingCouldNotStart)
        case .ignored:
            // The recorder was starting or stopping, and the press did nothing. If it moved
            // the control, the control goes back to what the coordinator is doing now.
            guard let before else { return }
            phase = await coordinator.isRecording ? before : .idle
        }
    }

    /// A recording that ended by itself: at its limit, by a call, or because its input or its
    /// drive failed. It is where it will stay when this is told.
    private func ended(_ ended: WatchCoordinator.RecordingEndedByItself) {
        endedByThemselves.insert(ended.captureID)
        let fate = RecordFate(ended.outcome)
        phase = .idle
        status = .stoppedEarly(EarlyStop(ended.ending), fate)
        announcer.announce(fate.announcement)
    }
}
