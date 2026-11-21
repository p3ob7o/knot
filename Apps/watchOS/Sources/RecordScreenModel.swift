import Foundation
import KnotCore
import KnotLink
import KnotUI
import Observation

/// What the record screen says under its control. Every outcome of a press has words, and
/// nothing implies that Knot is recording until the recording is live (docs/product-spec.md
/// §4.5).
enum RecordStatus: Equatable, Sendable {
    /// Nothing to say: the app has just opened, or a press is starting a recording.
    case ready
    /// The recording is live.
    case recording
    /// The recording stopped and is kept on the Watch, to be sent to the iPhone.
    case saved
    /// The recording stopped and is kept on the Watch, but a step failed for good, so it
    /// cannot be sent.
    case savedNotSendable
    /// A tap-started recording stopped within a second, or one that held no audio.
    case nothingKept
    /// The recording could not start, for this reason.
    case couldNotStart(RecordFailure)

    /// The words on the screen, or `nil` for none.
    var text: String? {
        switch self {
        case .ready: nil
        case .recording: String(localized: "Recording")
        case .saved: String(localized: "Saved")
        case .savedNotSendable: String(localized: "Saved on this Watch. It can't be sent to the iPhone.")
        case .nothingKept: String(localized: "Too short. Nothing was kept.")
        case .couldNotStart(let failure): String(localized: "Couldn't start recording. \(failure.text)")
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

    init(composition: WatchComposition, announcer: any Announcer = VoiceOverAnnouncer()) {
        self.composition = composition
        self.announcer = announcer
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
            phase = .recording(capture)
            status = .recording
            announcer.announce(.recordingStarted)
        case .stopped(let stop):
            phase = .idle
            switch stop {
            case .sent, .acknowledged:
                status = .saved
                announcer.announce(.recordingStopped)
            case .kept(_, let error):
                status = error.isFinal ? .savedNotSendable : .saved
                announcer.announce(.recordingStopped)
            case .endedWithoutAudio:
                status = .nothingKept
                announcer.announce(.recordingDiscarded)
            }
        case .discarded:
            phase = .idle
            status = .nothingKept
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
}
