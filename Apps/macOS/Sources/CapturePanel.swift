import AppKit
import Carbon
import KnotCore
import KnotUI
import Observation
import SwiftUI

@MainActor
final class CapturePanelWindow: NSPanel {
    var onInteraction: (() -> Void)?
    var onEscape: (() -> Void)?
    var onDone: (() -> Void)?
    var onNewNote: (() -> Void)?
    var acceptsKeyboard = false

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 128),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .ignoresCycle]
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        setAccessibilityLabel("Knot capture")
    }

    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape),
            Hotkey.Modifiers(eventFlags: event.modifierFlags).isEmpty
        {
            onEscape?()
            return
        }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown:
            onInteraction?()
        default:
            break
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = Hotkey.Modifiers(eventFlags: event.modifierFlags)
        guard flags == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "\r": onDone?()
        case "n": onNewNote?()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
@Observable
final class CapturePanel: NSObject, NSWindowDelegate {
    let model: NoteViewModel
    private let window = CapturePanelWindow()
    private var dismissal = PanelDismissal()
    private var screen: NSScreen?
    private var globalMouse: Any?
    private var localMouse: Any?
    private var hideTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private(set) var presentation: PanelPresentation = .typing
    private(set) var focusRequest = 0
    private(set) var maxHeight: CGFloat = 380
    private(set) var held = false
    private(set) var continuesNote: Bool?
    private(set) var finished: CaptureState?
    var needsHotkey = false
    var externalProblem: SurfaceProblem?
    var stopOrStart: (() -> Void)?
    var openSettings: (() -> Void)?
    var isVisible: Bool { window.isVisible }
    var isKey: Bool { window.isKeyWindow }
    private var outcomeRecord: NoteRecord?

    init(model: NoteViewModel) {
        self.model = model
        super.init()
        window.delegate = self
        window.onInteraction = { [weak self] in self?.interact() }
        window.onEscape = { [weak self] in
            guard let self else { return }
            if model.recording.isRecording { stopOrStart?() } else { close() }
        }
        window.onDone = { [weak self] in self?.done() }
        window.onNewNote = { [weak self] in self?.newNote() }
        window.contentView = NSHostingView(rootView: CapturePanelPage(panel: self))
    }

    func toggleTyping() {
        if isVisible, model.recording == .idle { close() } else { showTyping() }
    }

    func showTyping() {
        if !isVisible { model.followWindowOnPresentation() }
        if model.recording == .idle {
            finished = nil
            externalProblem = nil
        }
        show(.typing)
    }

    func showRecording(held: Bool, continuing: Bool?) {
        self.held = held
        continuesNote = continuing
        finished = nil
        externalProblem = nil
        if isVisible, window.isKeyWindow {
            hideTask?.cancel()
            return
        }
        show(.recording)
    }

    func decidedDestination(_ continues: Bool) {
        continuesNote = continues
    }

    func ended(_ state: CaptureState) {
        outcomeRecord = nil
        finished = state
        held = false
        if state.outcome == .discardedEmpty { scheduleAutoHide() }
    }

    var finalSegment: Segment? {
        guard let finished else { return nil }
        return outcomeRecord?.liveSegments.first { $0.id == SegmentID(finished.captureID) }
    }

    func updateOutcome(_ record: NoteRecord, for capture: CaptureID) {
        guard finished?.captureID == capture else { return }
        outcomeRecord = record
        updateAutoHide()
    }

    /// Waits for a terminal text state. Durable audio can outlive this panel and its tasks.
    func updateAutoHide() {
        guard finished?.outcome == .stored, let finalSegment else { return }
        switch finalSegment.state {
        case .voice(.ready), .voice(.failed):
            scheduleAutoHide()
        default:
            break
        }
    }

    private func scheduleAutoHide() {
        guard dismissal.canAutoHide, hideTask == nil, finished?.recordingEnding == nil else { return }
        hideTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            self?.close()
        }
    }

    private func show(_ presentation: PanelPresentation) {
        hideTask?.cancel()
        hideTask = nil
        closeTask?.cancel()
        closeTask = nil
        if !isVisible {
            screen = NSScreen.main ?? NSScreen.screens.first
            if let screen {
                maxHeight = screen.visibleFrame.height / 2
                resize(window.frame.height)
            }
        }
        self.presentation = presentation
        dismissal.show(presentation)
        window.acceptsKeyboard = presentation.takesKeyboard
        if presentation.takesKeyboard {
            window.makeKeyAndOrderFront(nil)
            focusRequest += 1
        } else {
            window.orderFrontRegardless()
        }
        monitorOutsideClicks()
    }

    func done() {
        guard model.fieldAcceptsTyping else { return }
        model.endCapture()
    }

    func newNote() {
        guard model.fieldAcceptsTyping else { return }
        finished = nil
        model.newNote()
        if window.isKeyWindow { focusRequest += 1 }
    }

    func edit(_ text: String) {
        interact()
        finished = nil
        model.fieldChanged(text)
    }

    private func interact() {
        dismissal.interacted()
        hideTask?.cancel()
        hideTask = nil
        if !window.acceptsKeyboard {
            window.acceptsKeyboard = true
            if model.recording == .idle { window.makeKey() }
        }
    }

    func close() {
        guard isVisible, closeTask == nil, model.recording == .idle else { return }
        model.endCapture()
        closeTask = Task { [weak self] in
            guard let self else { return }
            await model.settle()
            guard !Task.isCancelled else { return }
            closeTask = nil
            if case .couldNotSave = model.problem { return }
            stopMonitoringClicks()
            window.orderOut(nil)
            window.acceptsKeyboard = false
            finished = nil
            hideTask?.cancel()
            hideTask = nil
        }
    }

    func resize(_ height: CGFloat) {
        guard let frame = screen?.visibleFrame else { return }
        let size = NSSize(width: 640, height: min(maxHeight, height))
        let centerY = frame.minY + frame.height * (2.0 / 3)
        window.setFrame(
            NSRect(
                x: frame.midX - size.width / 2, y: centerY - size.height / 2, width: size.width, height: size.height),
            display: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        if presentation == .typing || window.acceptsKeyboard { close() }
    }

    private func monitorOutsideClicks() {
        guard localMouse == nil, globalMouse == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouse = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            if let self, event.window !== window, presentation == .typing { close() }
            return event
        }
        globalMouse = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self, self.presentation == .typing { self.close() }
            }
        }
    }

    private func stopMonitoringClicks() {
        if let localMouse { NSEvent.removeMonitor(localMouse) }
        if let globalMouse { NSEvent.removeMonitor(globalMouse) }
        localMouse = nil
        globalMouse = nil
    }
}

private struct CapturePanelPage: View {
    @Environment(\.knotTheme) private var theme
    @FocusState private var fieldFocused: Bool
    let panel: CapturePanel

    private var model: NoteViewModel { panel.model }
    private var phase: KnotUI.RecordingPhase { model.recording }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if phase == .idle, panel.finished == nil, let date = model.record?.note.lastCaptureEndedAt {
                Text("Adding to the note from \(date.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline).foregroundStyle(theme.colors[.textSecondary])
            }
            if let problem = panel.externalProblem ?? model.problem {
                Banner(problem.message, symbol: "exclamationmark.triangle", role: .failed) {
                    if problem == .couldNotStartRecording(KnotError.microphonePermissionRefused.code) {
                        Button("Open Settings", action: MacMicrophone.openPrivacySettings)
                    }
                }
            }
            if panel.needsHotkey, phase == .idle, panel.finished == nil {
                Banner("Tap your hotkey to type. Hold it to record.", symbol: "keyboard") {
                    Button("Choose Hotkey…") { panel.openSettings?() }
                }
            }
            page
            if model.recordingOutcome == .saveFailed {
                Banner(Announcement.recordingSaveFailed.text, symbol: "exclamationmark.triangle", role: .failed)
            }
            if let ending = panel.finished?.recordingEnding, let message = notice(ending) {
                Banner(message, symbol: "stop.fill")
            }
            HStack {
                Text(hints)
                    .font(.subheadline).foregroundStyle(theme.colors[.textSecondary])
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if let elapsed = model.recordingElapsed {
                        Text(ClockText.of(elapsed)).monospacedDigit().accessibilityHidden(true)
                    }
                }
                if model.recordingOutcome == .saved { Text("Saved") }
                RecordButton(phase: phase, elapsed: model.recordingElapsed, outcome: model.recordingOutcome) {
                    panel.stopOrStart?()
                }
                .frame(width: 28, height: 28)
            }
        }
        .padding(20)
        .frame(width: 640)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(in: RoundedRectangle(cornerRadius: 26))
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { panel.resize($0) }
        .onChange(of: panel.focusRequest, initial: true) { _, request in
            if request > 0 { fieldFocused = true }
        }
        .onChange(of: panel.finalSegment?.state) { _, _ in panel.updateAutoHide() }
        .task { await model.observeStore() }
        .task { await model.followWindow(every: .seconds(5)) }
    }

    @ViewBuilder private var page: some View {
        if phase.isRecording || phase == .stopping {
            let final = model.liveTranscript.final
            let volatile = model.liveTranscript.volatile
            if let continues = panel.continuesNote {
                Text(continues ? "Continuing a note" : "Starting a new note")
                    .font(.subheadline).foregroundStyle(theme.colors[.textSecondary])
            }
            if !final.isEmpty || !volatile.isEmpty {
                let stable = Text(final).foregroundStyle(theme.colors[.textPrimary])
                let incoming = Text(final.isEmpty ? volatile : " " + volatile)
                    .foregroundStyle(theme.colors[.textSecondary])
                ScrollView {
                    Text("\(stable)\(incoming)")
                        .font(.title2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: max(50, panel.maxHeight - 118))
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            if let segment = panel.finalSegment, !segment.text.isEmpty {
                Text(segment.text).font(.title2).lineLimit(maxLines)
            } else if panel.finished?.outcome == .stored {
                if case .voice(.ready) = panel.finalSegment?.state {
                    Text("Kept, no text")
                } else if case .voice(.failed) = panel.finalSegment?.state {
                    Text("Needs you")
                } else {
                    Text("Saved, text on its way")
                }
            } else if model.recordingOutcome == .discarded {
                Text("Too short. Nothing was kept.")
            }
            CaptureField(
                text: model.fieldText, acceptsTyping: model.fieldAcceptsTyping, isFocused: $fieldFocused,
                typeRole: .captureField, onChange: panel.edit, onSubmit: panel.done
            )
            .lineLimit(1...maxLines)
        }
    }

    private var maxLines: Int { max(1, Int((panel.maxHeight - 145) / 26)) }

    private var hints: String {
        if phase.isRecording { return panel.held ? "Release the hotkey to stop" : "Listening" }
        if phase == .stopping { return "Saving recording…" }
        return "⌘↩ Done, ⌘N New note, esc Close"
    }

    private func notice(_ ending: RecordingEndReason) -> String? {
        switch ending {
        case .limitReached: String(localized: "Recording stopped at 30 minutes and was saved.")
        case .interrupted: String(localized: "Recording was interrupted.")
        case .inputLost: String(localized: "Recording stopped because the microphone disconnected.")
        case .diskFull: String(localized: "Recording stopped because there isn’t enough space.")
        case .writeFailed: String(localized: "Recording stopped because Knot couldn’t save more audio.")
        case .recovered, .unknown: nil
        }
    }
}
