import AppKit
import KnotCore
import KnotUI
import Observation

@MainActor
protocol MacCapturePanel: AnyObject {
    var model: NoteViewModel { get }
    var held: Bool { get }
    var finished: CaptureState? { get }
    var isVisible: Bool { get }
    var needsHotkey: Bool { get set }
    var externalProblem: SurfaceProblem? { get set }
    var stopOrStart: (() -> Void)? { get set }

    func toggleTyping(_ presentation: PanelPresentation)
    func showRecording(held: Bool, continuing: Bool?, presentation: PanelPresentation)
    func decidedDestination(_ continues: Bool)
    func setRecordingLive(_ live: Bool)
    func ended(_ state: CaptureState)
    func updateOutcome(_ record: NoteRecord, for capture: CaptureID)
}

@MainActor
@Observable
final class MacCaptureCoordinator {
    private let panel: any MacCapturePanel
    private let environment: AppEnvironment
    private let hotkeys = CarbonHotkeys()
    private var preparation: HotkeyPreparation
    private let onboardingDefaults: UserDefaults?
    private static let onboardingKey = "v1.mac.hotkey-onboarding-complete"
    private var gesture = HotkeyGesture()
    private var mark: DispatchSourceTimer?
    private var polling: DispatchSourceTimer?
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var holdReleasedWhileStarting = false
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
        panel: any MacCapturePanel, environment: AppEnvironment,
        onboardingDefaults: UserDefaults?
    ) {
        self.panel = panel
        self.environment = environment
        preparation = HotkeyPreparation(recorder: environment.recorder)
        self.onboardingDefaults = onboardingDefaults
        hotkeys.onShortcut = { [weak self] down, time in self?.receive(down, at: time) }
        hotkeys.onEscape = { [weak self] in self?.stop() }
        panel.stopOrStart = { [weak self] in self?.toggleRecording() }
    }

    func loadShortcut() async {
        guard let settings = try? await environment.settings.load() else { return }
        guard let hotkey = settings.hotkey else {
            panel.needsHotkey = onboardingDefaults?.bool(forKey: Self.onboardingKey) != true
            return
        }
        do {
            hotkeys.use(try hotkeys.reserve(hotkey))
            shortcut = hotkey
            onboardingDefaults?.set(true, forKey: Self.onboardingKey)
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
            onboardingDefaults?.set(true, forKey: Self.onboardingKey)
            panel.needsHotkey = false
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
            guard startTask == nil else { return }
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
            apply(gesture.release(at: time), fromCarbonRelease: true)
        }
    }

    private func cancelMark() {
        mark?.cancel()
        mark = nil
    }

    func apply(_ effects: [HotkeyEffect], fromCarbonRelease: Bool = false) {
        for effect in effects {
            preparation.apply(effect)
            switch effect {
            case .prepareMicrophone, .releaseMicrophone:
                break
            case .tap:
                panel.toggleTyping(.typing)
            case .startHoldRecording:
                start(held: true, presentation: .recording)
                watchModifiers()
            case .stopRecording:
                stopRecording(fromCarbonRelease: fromCarbonRelease)
            }
        }
    }

    private func watchModifiers() {
        guard let required = shortcut?.modifiers, !required.isEmpty else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, startTask == nil else { return }
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

    func start(held: Bool, presentation: PanelPresentation = .recording) {
        guard startTask == nil, stopTask == nil, !isLive, panel.model.recording == .idle else { return }
        let model = panel.model.fieldText.isEmpty ? (mainDraft?() ?? panel.model) : panel.model
        recordingModel = model
        holdReleasedWhileStarting = false
        let prior = model.noteID
        panel.showRecording(held: held, continuing: prior != nil, presentation: presentation)
        model.press(held ? .holdStart : .tap)
        startTask = Task { [weak self] in
            await model.settle()
            guard let self else { return }
            startTask = nil
            if model.recording.isRecording {
                if let note = model.noteID {
                    panel.decidedDestination(note == prior || (model.record?.liveSegments.count ?? 0) > 1)
                }
                if holdReleasedWhileStarting { stopRecording() }
            } else {
                _ = gesture.receive(.escape)
                cancelPolling()
                if model !== panel.model { panel.externalProblem = model.problem }
                recordingModel = nil
            }
        }
    }

    func stop() {
        guard startTask == nil else { return }
        cancelMark()
        let effects = gesture.receive(.escape)
        apply(effects)
        if !effects.contains(.stopRecording), isLive || startTask != nil || panel.model.recording.isRecording {
            stopRecording()
        }
    }

    private func stopRecording(fromCarbonRelease: Bool = false) {
        if startTask != nil {
            if fromCarbonRelease, panel.held {
                holdReleasedWhileStarting = true
                cancelPolling()
            }
            return
        }
        guard stopTask == nil else { return }
        let model = recordingModel ?? panel.model
        guard model.recording.isRecording else { return }
        cancelPolling()
        model.press(model.isHeldRecording ? .holdRelease : .tap)
        stopTask = Task { [weak self] in
            await model.settle()
            self?.stopTask = nil
        }
    }

    func startFromIntent() async throws {
        guard startTask == nil, stopTask == nil, !isLive, panel.model.recording == .idle else { return }
        start(held: false)
        let model = recordingModel ?? panel.model
        let previous = model.lastRecording
        await startTask?.value
        if !model.recording.isRecording, model.lastRecording == previous {
            throw RecordingIntentError(
                message: model.problem?.message ?? String(localized: "Knot couldn’t start recording."))
        }
    }

    func stopFromIntent() async throws {
        guard startTask == nil, stopTask == nil else { return }
        let model = recordingModel ?? panel.model
        stop()
        guard let operation = stopTask else { return }
        await operation.value
        if model.recording.isRecording || model.recordingOutcome == .saveFailed {
            throw RecordingIntentError(message: String(localized: "Knot couldn’t stop and save the recording."))
        }
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
                    panel.showRecording(held: false, continuing: nil, presentation: .recording)
                    panel.externalProblem = model.problem
                }
            }
        }
    }

    private func setLive(_ live: Bool) {
        guard live != isLive else { return }
        isLive = live
        panel.setRecordingLive(live)
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

    func stopAndSettle() async {
        let model = recordingModel ?? panel.model
        await startTask?.value
        stop()
        await stopTask?.value
        await model.settle()
    }

    func shutDown() {
        hotkeys.tearDown()
        cancelMark()
        cancelPolling()
    }
}

private struct RecordingIntentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
