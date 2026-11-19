import AppKit
import Carbon
import Observation

/// One press, as the window and the log show it. Times in milliseconds.
struct PressRecord: Identifiable, Sendable {
    enum Kind: String, Sendable { case tap, hold }

    let id = UUID()
    var index: Int
    var kind: Kind = .tap
    var synthetic = false
    var mode: MicrophoneMode = .atMark
    var behaviour: PanelBehaviour = .a
    var policy = "accessory"
    var transport = "none"
    /// From the press's event time to its handler.
    var pressDeliveryMS: Double?
    var releaseDeliveryMS: Double?
    var prepareMS: Double?
    /// Tap: from the release's event time to a key panel with the cursor in its field.
    var releaseToReadyMS: Double?
    /// Tap: the same, to the next turn of the main run loop, after the panel has drawn.
    var releaseToDrawnMS: Double?
    var focused: Bool?
    /// How late the 250 ms timer fired.
    var markLateMS: Double?
    var startCallMS: Double?
    /// Hold: from the mark (key-down + 250 ms) to the first captured sample, the moment the
    /// microphone is live. Negative when the microphone opened at key-down.
    var markToLiveMS: Double?
    var downToLiveMS: Double?
    /// Hold: from the mark to the first buffer reaching the app, when "Listening" can show.
    /// Later than live by about one buffer (100 ms or more, per AVAudioNode.h).
    var markToShownMS: Double?
    /// Hold: from key-down to the first captured sample: the start of the hold that was not
    /// recorded.
    var unrecordedLeadMS: Double?
    var holdMS: Double?
    var stopReason: String?
    var onset: Onset?
    var keyPolls: [String] = []
    var otherAppStayedFront: Bool?
    var appActive: Bool?
    var panelVisible: Bool?
    var panelOnActiveSpace: Bool?
    var secureInput: Bool?
    var error: String?

    var summary: String {
        func f(_ value: Double?) -> String { value.map { String(format: "%.0f", $0) } ?? "–" }
        var parts = ["#\(index) \(kind.rawValue)\(synthetic ? " (synthetic)" : "")"]
        switch kind {
        case .tap:
            parts.append("release→ready \(f(releaseToReadyMS)) ms, drawn \(f(releaseToDrawnMS)) ms")
            if let focused { parts.append(focused ? "field focused" : "FIELD NOT FOCUSED") }
        case .hold:
            parts.append(
                "mark→live \(f(markToLiveMS)) ms, shown \(f(markToShownMS)) ms, unrecorded \(f(unrecordedLeadMS)) ms")
            if let onset { parts.append(onset.speechAtOpen ? "SPEECH AT OPEN" : "quiet at open") }
            if let stopReason { parts.append("stop: \(stopReason)") }
        }
        if let otherAppStayedFront { parts.append(otherAppStayedFront ? "other app kept front" : "KNOT TOOK FRONT") }
        if let panelVisible { parts.append(panelVisible ? "panel visible" : "PANEL NOT VISIBLE") }
        if secureInput == true { parts.append("secure input on") }
        if let error { parts.append("error: \(error)") }
        return parts.joined(separator: " · ")
    }

    var logFields: [String: String] {
        var fields: [String: String] = [
            "index": String(index), "kind": kind.rawValue, "synthetic": String(synthetic),
            "mode": mode.rawValue, "panel": String(behaviour.rawValue.prefix(1)), "policy": policy,
            "transport": transport,
        ]
        let numbers: [(String, Double?)] = [
            ("pressDeliveryMS", pressDeliveryMS), ("releaseDeliveryMS", releaseDeliveryMS),
            ("prepareMS", prepareMS), ("releaseToReadyMS", releaseToReadyMS),
            ("releaseToDrawnMS", releaseToDrawnMS), ("markLateMS", markLateMS), ("startCallMS", startCallMS),
            ("markToLiveMS", markToLiveMS), ("downToLiveMS", downToLiveMS), ("markToShownMS", markToShownMS),
            ("unrecordedLeadMS", unrecordedLeadMS), ("holdMS", holdMS),
        ]
        for (key, value) in numbers { if let value { fields[key] = String(format: "%.1f", value) } }
        if let focused { fields["focused"] = String(focused) }
        if let stopReason { fields["stop"] = stopReason }
        if let onset {
            fields["onsetFirstDB"] = String(format: "%.1f", onset.firstDB)
            fields["onsetPeakDB"] = String(format: "%.1f", onset.peakDB)
            fields["speechAtOpen"] = String(onset.speechAtOpen)
            fields["seconds"] = String(format: "%.2f", onset.seconds)
        }
        if !keyPolls.isEmpty { fields["keyPolls"] = keyPolls.joined(separator: "|") }
        if let otherAppStayedFront { fields["otherAppStayedFront"] = String(otherAppStayedFront) }
        if let appActive { fields["appActive"] = String(appActive) }
        if let panelVisible { fields["panelVisible"] = String(panelVisible) }
        if let panelOnActiveSpace { fields["panelOnActiveSpace"] = String(panelOnActiveSpace) }
        if let secureInput { fields["secureInput"] = String(secureInput) }
        if let error { fields["error"] = error }
        return fields
    }
}

/// Everything the window shows.
@MainActor
@Observable
final class SpikeModel {
    var hotKey: HotKeySpec?
    var registration = "no key chosen"
    var choosing = false
    var chooserMessage = ""
    var mode: MicrophoneMode = .atMark
    var behaviour: PanelBehaviour = .b
    var keySource: KeyStateReader.Source = .session
    var ignoreReleases = false
    var records: [PressRecord] = []
    var lastHold: CaptureBuffer.State?
    var environment: [(String, String)] = []
    var tapStatus = "not started"
    var tapSeen = ""
    var repeats = 0

    func summary(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "no runs yet" }
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        return String(format: "median %.0f ms, p95 %.0f ms, n %d", median, p95, values.count)
    }

    var tapSummary: String {
        summary(records.filter { $0.kind == .tap && !$0.synthetic }.compactMap(\.releaseToReadyMS))
    }

    var holdSummary: String {
        summary(records.filter { $0.kind == .hold && !$0.synthetic && $0.mode == .atMark }.compactMap(\.markToLiveMS))
    }

    var keyDownSummary: String {
        summary(
            records.filter { $0.kind == .hold && !$0.synthetic && $0.mode == .atKeyDown }.compactMap(\.downToLiveMS))
    }
}

/// Joins the hot key's events, the press machine, the microphone and the panel, and measures
/// each press. In the self-test it runs headless: it records the machine's effects and carries
/// out none of them, so no panel shows and no microphone is touched.
@MainActor
final class PressController {
    static let hotKeyID: UInt32 = 1
    static let escapeID: UInt32 = 2

    let model: SpikeModel
    let headless: Bool
    private var machine = PressMachine()
    private let microphone = Microphone()
    private let playback = Playback()
    private lazy var panel = PanelHost()
    private var current: PressRecord?
    private var downTime: Double = 0
    private var releaseTime: Double = 0
    private var markTimer: (any DispatchSourceTimer)?
    private var pollTimer: Timer?
    private var hideTimer: DispatchWorkItem?
    private var frontmostAtPress: pid_t?
    private var count = 0
    private var pollSeconds = 0
    private(set) var effectsLog: [String] = []
    var onRecordingChange: ((Bool) -> Void)?

    init(model: SpikeModel, headless: Bool) {
        self.model = model
        self.headless = headless
        HotKeyCenter.shared.onEvent = { [weak self] event in self?.handle(event) }
    }

    // MARK: Settings

    func setUpPanel() {
        guard !headless else { return }
        panel.panel.onEscape = { [weak self] in self?.apply(self?.machine.escape() ?? []) }
        panel.model.stop = { [weak self] in self?.apply(self?.machine.stopControl() ?? []) }
        panel.panel.apply(model.behaviour)
    }

    func setBehaviour(_ behaviour: PanelBehaviour) {
        model.behaviour = behaviour
        if !headless { panel.panel.apply(behaviour) }
    }

    func setMode(_ mode: MicrophoneMode) {
        model.mode = mode
        machine.mode = mode
    }

    /// Registers the chosen key, exclusively when it can, so that a key another app holds is
    /// noticed (CarbonEvents.h, kEventHotKeyExclusive).
    func register(_ spec: HotKeySpec) {
        let exclusive = HotKeyCenter.shared.register(spec, id: Self.hotKeyID, exclusive: true)
        var text = "registered \(spec.label), exclusive (status \(exclusive))"
        if exclusive != noErr {
            let shared = HotKeyCenter.shared.register(spec, id: Self.hotKeyID, exclusive: false)
            text =
                shared == noErr
                ? "registered \(spec.label), shared: exclusive refused (\(exclusive)), so another app holds it"
                : "NOT registered \(spec.label): exclusive \(exclusive), shared \(shared)"
        }
        model.hotKey = spec
        model.registration = text
        EventTapFallback.shared.keyCode = UInt16(spec.keyCode)
        SP5Log.record(
            "hotkey.register",
            [
                "keyCode": String(spec.keyCode), "modifiers": String(spec.modifiers),
                "exclusiveStatus": String(exclusive),
            ])
    }

    func unregister() {
        HotKeyCenter.shared.unregister(id: Self.hotKeyID)
        model.registration = "not registered while choosing"
    }

    func playLastHold() {
        guard let hold = model.lastHold else { return }
        playback.play(hold.samples, sampleRate: hold.sampleRate)
    }

    // MARK: Events

    private func handle(_ event: HotKeyEvent) {
        if event.id == Self.escapeID {
            if event.kind == .pressed { apply(machine.escape()) }
            return
        }
        guard event.id == Self.hotKeyID else { return }
        let delivery = (event.deliveredAt - event.eventTime) * 1000
        SP5Log.record(
            "hotkey.\(event.kind.rawValue)",
            ["deliveryMS": String(format: "%.1f", delivery), "synthetic": String(event.synthetic)])
        switch event.kind {
        case .pressed:
            let fresh = machine.phase == .idle
            if fresh { begin(event, delivery: delivery) }
            let before = machine.repeats
            apply(machine.keyDown(at: event.eventTime))
            if machine.repeats != before { model.repeats = machine.repeats }
            if fresh { scheduleMark(from: event.eventTime) }
        case .released:
            if model.ignoreReleases, machine.isRecording, !event.synthetic {
                SP5Log.record("hotkey.release-ignored", ["reason": "simulated missed release"])
                current?.keyPolls.append("release ignored on purpose")
                return
            }
            releaseTime = event.eventTime
            current?.releaseDeliveryMS = delivery
            if machine.isRecording { current?.holdMS = (event.eventTime - downTime) * 1000 }
            markTimer?.cancel()
            apply(machine.keyUp(at: event.eventTime))
        }
    }

    private func begin(_ event: HotKeyEvent, delivery: Double) {
        count += 1
        downTime = event.eventTime
        frontmostAtPress = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var record = PressRecord(index: count)
        record.synthetic = event.synthetic
        record.mode = model.mode
        record.behaviour = model.behaviour
        record.policy = NSApp.activationPolicy() == .regular ? "regular" : "accessory"
        record.pressDeliveryMS = delivery
        record.secureInput = Permissions.secureInput
        record.transport = headless ? "untouched" : InputDevice.current().transport
        current = record
        hideTimer?.cancel()
    }

    /// A strict timer with no leeway: `asyncAfter` fired about 10 ms late in the self-test.
    private func scheduleMark(from downAt: Double) {
        markTimer?.cancel()
        let delay = max(0, downAt + PressMachine.threshold - Clock.now())
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now() + delay, repeating: .never, leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Clock.now()
                self.current?.markLateMS = (now - (downAt + PressMachine.threshold)) * 1000
                self.apply(self.machine.markReached(at: now))
            }
        }
        markTimer = timer
        timer.resume()
    }

    // MARK: Effects

    private func apply(_ effects: [PressEffect]) {
        for effect in effects {
            effectsLog.append(String(describing: effect))
            guard !headless else { continue }
            perform(effect)
        }
        if headless, effects.contains(where: { if case .stopRecording = $0 { true } else { false } }) {
            finish(kind: .hold)
        } else if headless, effects.contains(.showPanelForTyping) || effects.contains(.hidePanel) {
            finish(kind: .tap)
        }
    }

    private func perform(_ effect: PressEffect) {
        switch effect {
        case .prepareMicrophone:
            switch microphone.prepare() {
            case .success(let prepared): current?.prepareMS = prepared.duration * 1000
            case .failure(let error): current?.error = error.text
            }
        case .openMicrophone:
            open()
        case .discardMicrophone:
            microphone.discard()
        case .showPanelForTyping:
            let focused = panel.showForTyping()
            let ready = Clock.now()
            current?.kind = .tap
            current?.focused = focused
            current?.releaseToReadyMS = (ready - releaseTime) * 1000
            panel.model.recording = false
            panel.model.title = "Ready for typing"
            panel.model.detail = "Tap the key again, or press Esc, to hide."
            panel.model.keyLines = []
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.panel.panel.displayIfNeeded()
                self.current?.releaseToDrawnMS = (Clock.now() - self.releaseTime) * 1000
                self.checkPlacement(then: { self.finish(kind: .tap) })
            }
        case .showPanelListening:
            current?.kind = .hold
            panel.model.recording = true
            panel.model.title = model.mode == .atMark ? "Opening the microphone…" : "Listening"
            panel.model.detail = "Release the key to stop."
            panel.model.keyLines = []
            panel.model.lines = []
            panel.showListening()
            onRecordingChange?(true)
        case .hidePanel:
            panel.hide()
            current?.kind = .tap
            finish(kind: .tap)
        case .stopRecording(let reason):
            stopRecording(reason)
        case .armEscape:
            let status = HotKeyCenter.shared.register(.escape, id: Self.escapeID, exclusive: false)
            SP5Log.record("escape.arm", ["status": String(status)])
            startPolling()
        case .disarmEscape:
            HotKeyCenter.shared.unregister(id: Self.escapeID)
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private func open() {
        if microphone.buffer == nil {
            if case .failure(let error) = microphone.prepare() {
                current?.error = error.text
                panel.model.title = "Cannot record: \(error.text)"
                return
            }
        }
        switch microphone.open() {
        case .success(let duration): current?.startCallMS = duration * 1000
        case .failure(let error):
            current?.error = error.text
            panel.model.title = "Cannot record: \(error.text)"
            return
        }
        waitForFirstBuffer(deadline: Clock.now() + 3)
    }

    /// Polls the tap's state every 2 ms until the first buffer has arrived, then shows the
    /// listening state. The time of "live" is the buffer's own arrival time, not this poll's.
    private func waitForFirstBuffer(deadline: Double) {
        guard let buffer = microphone.buffer else { return }
        let state = buffer.snapshot()
        if let delivered = state.firstDeliveredAt {
            let mark = downTime + PressMachine.threshold
            current?.markToShownMS = (delivered - mark) * 1000
            if let first = state.firstSampleTime {
                current?.downToLiveMS = (first - downTime) * 1000
                current?.markToLiveMS = (first - mark) * 1000
                current?.unrecordedLeadMS = (first - downTime) * 1000
            } else {
                current?.error = "the first buffer has no host time"
            }
            if machine.isRecording {
                panel.model.title = "Listening"
            }
            return
        }
        guard Clock.now() < deadline else {
            current?.error = "no audio within 3 s"
            panel.model.title = "No audio arrived"
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { [weak self] in
            self?.waitForFirstBuffer(deadline: deadline)
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollSeconds = 0
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let spec = self.model.hotKey ?? (self.headless ? HotKeySpec.selfTest : nil) else {
                    return
                }
                self.pollSeconds += 1
                let seconds = self.pollSeconds
                let reading = KeyStateReader.read(spec)
                func word(_ down: Bool) -> String { down ? "down" : "up" }
                let line =
                    "\(seconds) s: session \(word(reading.session)), HID \(word(reading.hid)), modifiers \(word(reading.modifiers))"
                self.current?.keyPolls.append(line)
                self.panel.model.keyLines.append(line)
                SP5Log.record(
                    "keystate.poll",
                    [
                        "second": String(seconds), "session": String(reading.session), "hid": String(reading.hid),
                        "modifiers": String(reading.modifiers),
                    ])
                let isDown: Bool
                switch self.model.keySource {
                case .session: isDown = reading.session
                case .hid: isDown = reading.hid
                case .off: return
                }
                self.apply(self.machine.keyState(isDown: isDown, at: Clock.now()))
            }
        }
    }

    private func stopRecording(_ reason: StopReason) {
        current?.stopReason = reason.rawValue
        current?.kind = .hold
        let state = microphone.stop()
        if let state, !state.samples.isEmpty {
            model.lastHold = state
            current?.onset = Onset.analyse(state.samples, sampleRate: state.sampleRate)
        }
        onRecordingChange?(false)
        panel.model.recording = false
        panel.model.title = "Saved (kept in memory only)"
        let record = current
        var lines: [String] = []
        if let record {
            func f(_ v: Double?) -> String { v.map { String(format: "%.0f ms", $0) } ?? "–" }
            lines.append("mark → live: \(f(record.markToLiveMS))   key-down → live: \(f(record.downToLiveMS))")
            lines.append("mark → \"Listening\" shown: \(f(record.markToShownMS))")
            lines.append("not recorded from key-down: \(f(record.unrecordedLeadMS))   held: \(f(record.holdMS))")
            if let onset = record.onset {
                lines.append(
                    String(
                        format: "start %.0f dBFS, loudest %.0f dBFS: %@", onset.firstDB, onset.peakDB,
                        onset.speechAtOpen ? "speech already under way at open" : "quiet at open"))
            }
            lines.append("stopped by: \(reason.rawValue)")
        }
        panel.model.lines = lines
        checkPlacement(then: { [weak self] in self?.finish(kind: .hold) })
        let hide = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.machine.isRecording else { return }
                if self.panel.panel.frame.contains(NSEvent.mouseLocation) || self.panel.panel.isKeyWindow { return }
                self.panel.hide()
                self.machine.panelShowing = false
            }
        }
        hideTimer = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: hide)
    }

    /// After a short wait, whether the panel is on screen and whether the app in front stayed
    /// in front. Neither reads a window's title or an app's name.
    private func checkPlacement(then done: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if let before = self.frontmostAtPress, before != getpid() {
                self.current?.otherAppStayedFront = front == before
            }
            self.current?.appActive = NSApp.isActive
            self.current?.panelVisible = self.panel.panel.occlusionState.contains(.visible)
            self.current?.panelOnActiveSpace = self.panel.panel.isOnActiveSpace
            done()
        }
    }

    private func finish(kind: PressRecord.Kind) {
        guard var record = current else { return }
        record.kind = kind
        current = nil
        SP5Log.record("press", record.logFields)
        model.records.insert(record, at: 0)
        if model.records.count > 60 { model.records.removeLast() }
    }
}
