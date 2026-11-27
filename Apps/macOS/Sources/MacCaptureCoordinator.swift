import AppKit
import KnotCore
import KnotUI
import Observation

@MainActor
@Observable
final class MacCaptureCoordinator {
    let panel: CapturePanel
    private let environment: AppEnvironment
    private let hotkeys = CarbonHotkeys()
    private let releasePreparation: @Sendable () async -> Void
    private var preparation: Task<Void, Never>?
    private var gesture = HotkeyGesture()
    private var mark: DispatchSourceTimer?
    private var polling: DispatchSourceTimer?
    private var startTask: Task<Void, Never>?
    private var stopAfterStart = false
    private var recordingModel: NoteViewModel?
    private var activeID: CaptureID?
    private var savingHotkey = false
    private(set) var shortcut: Hotkey?
    private(set) var shortcutProblem: String?
    private(set) var isLive = false

    var mainModel: (() -> NoteViewModel?)?
    var mainDraft: (() -> NoteViewModel?)?
    var showRecordingIndicator: ((Bool) -> Void)?

    init(
        panel: CapturePanel, environment: AppEnvironment,
        releasePreparation: @escaping @Sendable () async -> Void = {}
    ) {
        self.panel = panel
        self.environment = environment
        self.releasePreparation = releasePreparation
        hotkeys.onShortcut = { [weak self] down, time in self?.receive(down, at: time) }
        hotkeys.onEscape = { [weak self] in self?.stop() }
        panel.stopOrStart = { [weak self] in self?.toggleRecording() }
    }

    func loadShortcut() async {
        guard let settings = try? await environment.settings.load() else { return }
        guard let hotkey = settings.hotkey else {
            panel.needsHotkey = true
            return
        }
        do {
            hotkeys.use(try hotkeys.reserve(hotkey))
            shortcut = hotkey
        } catch {
            shortcutProblem = Self.message(error)
            panel.needsHotkey = true
        }
    }

    func saveShortcut(_ candidate: Hotkey?) async -> Bool {
        guard !savingHotkey, gesture.state == .idle, !isLive, startTask == nil else {
            shortcutProblem = "Finish the current recording or hotkey press first."
            return false
        }
        savingHotkey = true
        defer { savingHotkey = false }
        shortcutProblem = nil
        do throws(KnotError) {
            var settings = try await environment.settings.load()
            let replacement: CarbonHotkeys.Registration?
            if let candidate, candidate != shortcut {
                replacement = try hotkeys.reserve(candidate)
            } else {
                replacement = nil
            }
            do {
                settings.hotkey = candidate
                try await environment.settings.save(settings)
            } catch {
                hotkeys.release(replacement)
                throw error
            }
            if candidate != shortcut { hotkeys.use(replacement) }
            shortcut = candidate
            panel.needsHotkey = candidate == nil
            return true
        } catch {
            shortcutProblem = Self.message(error)
            return false
        }
    }

    private static func message(_ error: KnotError) -> String {
        if error.code == KnotError.hotkeyTaken.code { return "This shortcut is already taken. Choose another one." }
        if error.code == KnotError.hotkeyInvalid.code { return "Choose a function key or a key with a modifier." }
        return "Knot couldn’t save the shortcut."
    }

    private func receive(_ down: Bool, at time: ContinuousClock.Instant) {
        guard !savingHotkey else { return }
        if down {
            if gesture.state == .idle, isLive || startTask != nil {
                stop()
                return
            }
            apply(gesture.receive(.keyDown(at: time)))
            if case .pressed(let since) = gesture.state, mark == nil {
                let remaining = max(.zero, HotkeyMachine.markDeadline(after: since) - ContinuousClock.now)
                let parts = remaining.components
                let nanos = Int(parts.seconds) * 1_000_000_000 + Int(parts.attoseconds / 1_000_000_000)
                let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
                timer.schedule(deadline: .now() + .nanoseconds(nanos), leeway: .nanoseconds(0))
                timer.setEventHandler { [weak self] in
                    guard let self, gesture.state == .pressed(since: since) else { return }
                    cancelMark()
                    apply(gesture.receive(.markReached(forKeyDownAt: since)))
                }
                mark = timer
                timer.resume()
            }
        } else {
            cancelMark()
            apply(gesture.release(at: time))
        }
    }

    private func cancelMark() {
        mark?.cancel()
        mark = nil
    }

    private func apply(_ effects: [HotkeyEffect]) {
        for effect in effects {
            switch effect {
            case .prepareMicrophone:
                let recorder = environment.recorder
                let previous = preparation
                preparation = Task {
                    await previous?.value
                    await recorder.prepare()
                }
            case .releaseMicrophone:
                let previous = preparation
                let releasePreparation = releasePreparation
                preparation = Task {
                    await previous?.value
                    await releasePreparation()
                }
            case .tap:
                panel.toggleTyping()
            case .startHoldRecording:
                start(held: true)
                watchModifiers()
            case .stopRecording:
                stopRecording()
            }
        }
    }

    private func watchModifiers() {
        guard let required = shortcut?.modifiers, !required.isEmpty else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let modifiers = Hotkey.Modifiers(eventFlags: NSEvent.modifierFlags)
            apply(gesture.checkModifiers(required: required, held: modifiers))
        }
        polling = timer
        timer.resume()
    }

    func toggleRecording() {
        if isLive || startTask != nil || panel.model.recording.isRecording {
            stop()
        } else if panel.model.recording == .idle {
            start(held: false)
        }
    }

    func start(held: Bool) {
        guard startTask == nil, !isLive, panel.model.recording == .idle else { return }
        let model = panel.model.fieldText.isEmpty ? (mainDraft?() ?? panel.model) : panel.model
        recordingModel = model
        stopAfterStart = false
        let prior = model.noteID
        panel.showRecording(held: held, continuing: prior != nil)
        model.press(held ? .holdStart : .tap)
        startTask = Task { [weak self] in
            await model.settle()
            guard let self else { return }
            startTask = nil
            if model.recording.isRecording {
                if let note = model.noteID {
                    panel.decidedDestination(note == prior || (model.record?.liveSegments.count ?? 0) > 1)
                }
                if stopAfterStart { stopRecording() }
            } else {
                _ = gesture.receive(.escape)
                cancelPolling()
                if model !== panel.model { panel.externalProblem = model.problem }
                recordingModel = nil
            }
        }
    }

    func stop() {
        cancelMark()
        let effects = gesture.receive(.escape)
        apply(effects)
        if !effects.contains(.stopRecording), isLive || startTask != nil || panel.model.recording.isRecording {
            stopRecording()
        }
    }

    private func stopRecording() {
        cancelPolling()
        if startTask != nil {
            stopAfterStart = true
            return
        }
        let model = recordingModel ?? panel.model
        guard model.recording.isRecording else { return }
        model.press(model.isHeldRecording ? .holdRelease : .tap)
    }

    private func cancelPolling() {
        polling?.cancel()
        polling = nil
    }

    /// The recorder emits live only after its first buffer. It also decides which terminal
    /// cue the engine or recorder can emit, including for a stop that left audio in Inbox.
    func cue(_ cue: Cue) {
        switch cue {
        case .recordingLive:
            setLive(true)
        case .saved, .discarded, .stoppedEarly:
            setLive(false)
        case .couldNotStart:
            setLive(false)
            if startTask == nil, let model = mainModel?() {
                Task { [weak self] in
                    await model.settle()
                    guard let self, case .couldNotStartRecording = model.problem else { return }
                    panel.showRecording(held: false, continuing: nil)
                    panel.externalProblem = model.problem
                }
            }
        }
    }

    private func setLive(_ live: Bool) {
        guard live != isLive else { return }
        isLive = live
        if live {
            hotkeys.armEscape()
        } else {
            hotkeys.disarmEscape()
            cancelPolling()
            _ = gesture.receive(.escape)
        }
        showRecordingIndicator?(live)
    }

    func observeStates() async {
        for await state in environment.engine.states() where state.kind == .voice {
            if state.outcome == .open {
                guard state.liveSince != nil, activeID != state.captureID else { continue }
                activeID = state.captureID
                setLive(true)
            } else if state.captureID == activeID {
                activeID = nil
                setLive(false)
                if panel.isVisible {
                    panel.ended(state)
                    await refreshOutcome()
                }
                recordingModel = nil
            }
        }
    }

    func observeOutcome() async {
        for await _ in environment.notes.changeSignals() { await refreshOutcome() }
    }

    private func refreshOutcome() async {
        guard panel.isVisible, let finished = panel.finished, let id = finished.noteID,
            let record = try? await environment.notes.note(id)
        else { return }
        panel.updateOutcome(record, for: finished.captureID)
    }

    func finishForQuit() async {
        let model = recordingModel ?? panel.model
        stop()
        await startTask?.value
        await model.settle()
    }

    func shutDown() {
        hotkeys.tearDown()
        cancelMark()
        cancelPolling()
    }
}
