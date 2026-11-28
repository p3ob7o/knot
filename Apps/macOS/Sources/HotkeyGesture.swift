import Foundation
import KnotCore

/// Reconciles Carbon delivery with the shared press rules. The release timestamp is the
/// event's, so a delayed timer cannot turn a qualifying hold into a tap.
struct HotkeyGesture {
    private(set) var state: HotkeyState = .idle

    mutating func receive(_ event: HotkeyEvent) -> [HotkeyEffect] {
        let (next, effects) = HotkeyMachine.reduce(state, event)
        state = next
        return effects
    }

    mutating func release(at time: ContinuousClock.Instant) -> [HotkeyEffect] {
        var effects: [HotkeyEffect] = []
        if case .pressed(let down) = state, time >= HotkeyMachine.markDeadline(after: down) {
            effects = receive(.markReached(forKeyDownAt: down))
        }
        return effects + receive(.keyUp)
    }

    mutating func checkModifiers(required: Hotkey.Modifiers, held: Hotkey.Modifiers) -> [HotkeyEffect] {
        guard !required.isEmpty, !held.isSuperset(of: required) else { return [] }
        return receive(.keyFoundUp)
    }
}

enum PanelPresentation: Equatable {
    case typing
    case recording

    var takesKeyboard: Bool { self == .typing }
}

/// The passive panel can leave after an outcome until a person interacts with it.
struct PanelDismissal {
    private(set) var canAutoHide = false

    mutating func show(_ presentation: PanelPresentation) {
        canAutoHide = presentation == .recording
    }

    mutating func interacted() { canAutoHide = false }
}

extension HotkeyEffect {
    @MainActor
    func presentPanel(toggleTyping: (PanelPresentation) -> Void, startHold: (PanelPresentation) -> Void) {
        switch self {
        case .tap: toggleTyping(.typing)
        case .startHoldRecording: startHold(.recording)
        case .prepareMicrophone, .releaseMicrophone, .stopRecording: break
        }
    }
}

/// Applies preparation effects in Carbon event order even when the recorder suspends.
@MainActor
struct HotkeyPreparation {
    let recorder: any Recorder
    private(set) var pending: Task<Void, Never>?

    mutating func apply(_ effect: HotkeyEffect) {
        guard effect == .prepareMicrophone || effect == .releaseMicrophone else { return }
        let previous = pending
        let recorder = recorder
        pending = Task {
            await previous?.value
            if effect == .prepareMicrophone {
                await recorder.prepare()
            } else {
                await recorder.releasePreparation()
            }
        }
    }
}
