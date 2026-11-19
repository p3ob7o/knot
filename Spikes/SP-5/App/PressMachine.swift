import Foundation

/// When the microphone opens during a hold. `atMark` is the design of docs/architecture.md §15.
/// `atKeyDown` is the alternative its failure rule names: listen from key-down into a buffer
/// that a tap discards.
enum MicrophoneMode: String, CaseIterable, Sendable {
    case atMark = "at the 250 ms mark"
    case atKeyDown = "at key-down"
}

enum StopReason: String, Sendable {
    case released = "released"
    case keyStateUp = "key state read up"
    case escape = "Esc"
    case pressedAgain = "pressed again"
    case stopControl = "stop control"
}

/// What the machine asks the app to do. The machine itself does nothing and reads no clock:
/// every input carries its own time, so the self-test can drive it with a table.
enum PressEffect: Equatable, Sendable {
    case prepareMicrophone
    case openMicrophone
    case discardMicrophone
    case showPanelForTyping
    case showPanelListening
    case hidePanel
    case stopRecording(StopReason)
    case armEscape
    case disarmEscape
}

/// Separates a tap from a hold at 250 ms (product spec §6, docs/architecture.md §15).
///
/// - Key down: nothing shows. The microphone is prepared, or opened when the mode is `atKeyDown`.
/// - Released before the mark: a tap. The panel shows ready for typing, or hides if it was
///   showing. The microphone never opened (in `atMark`), and its preparation is dropped.
/// - Still held at the mark: a hold. The panel shows listening and the microphone opens.
/// - Released after a hold: the recording stops.
/// - A release that never arrives: the recording goes on until the key state reads up, Esc, a
///   second press or the stop control.
struct PressMachine: Sendable {
    static let threshold: Double = 0.250

    enum Phase: Equatable, Sendable {
        case idle
        case down(at: Double)
        case recording(downAt: Double)
        /// A second press stopped a recording whose release was missed. Its own release is
        /// swallowed, so that it is not read as a tap.
        case swallowingRelease
    }

    private(set) var phase: Phase = .idle
    var mode: MicrophoneMode = .atMark
    var panelShowing = false
    /// Presses that arrived while the key was already down: auto-repeat, if the system sends it.
    private(set) var repeats = 0

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    mutating func keyDown(at time: Double) -> [PressEffect] {
        switch phase {
        case .idle:
            phase = .down(at: time)
            return mode == .atMark ? [.prepareMicrophone] : [.prepareMicrophone, .openMicrophone]
        case .down:
            repeats += 1
            return []
        case .recording:
            phase = .swallowingRelease
            return [.stopRecording(.pressedAgain), .disarmEscape]
        case .swallowingRelease:
            repeats += 1
            return []
        }
    }

    /// Called when the timer set at key-down fires. `time` is when it fired.
    mutating func markReached(at time: Double) -> [PressEffect] {
        guard case .down(let downAt) = phase, time - downAt >= Self.threshold - 0.0005 else { return [] }
        return startHold(downAt: downAt)
    }

    mutating func keyUp(at time: Double) -> [PressEffect] {
        switch phase {
        case .idle:
            return []
        case .swallowingRelease:
            phase = .idle
            return []
        case .down(let downAt):
            if time - downAt < Self.threshold {
                phase = .idle
                let panel: PressEffect = panelShowing ? .hidePanel : .showPanelForTyping
                panelShowing.toggle()
                return [.discardMicrophone, panel]
            }
            // Released after the mark, before its timer ran: still a hold, already over.
            return startHold(downAt: downAt) + stop(.released)
        case .recording:
            return stop(.released)
        }
    }

    /// The key state, read once a second while recording.
    mutating func keyState(isDown: Bool, at time: Double) -> [PressEffect] {
        guard case .recording = phase, !isDown else { return [] }
        return stop(.keyStateUp)
    }

    mutating func escape() -> [PressEffect] {
        if case .recording = phase { return stop(.escape) }
        if panelShowing {
            panelShowing = false
            return [.hidePanel]
        }
        return []
    }

    mutating func stopControl() -> [PressEffect] {
        if case .recording = phase { return stop(.stopControl) }
        return []
    }

    private mutating func startHold(downAt: Double) -> [PressEffect] {
        phase = .recording(downAt: downAt)
        panelShowing = true
        let open: [PressEffect] = mode == .atMark ? [.openMicrophone] : []
        return [.showPanelListening] + open + [.armEscape]
    }

    private mutating func stop(_ reason: StopReason) -> [PressEffect] {
        phase = .idle
        return [.stopRecording(reason), .disarmEscape]
    }
}
