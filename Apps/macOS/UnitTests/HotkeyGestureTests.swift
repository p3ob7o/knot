import Foundation
import KnotCore
import KnotUI
import Testing

#if DEBUG || KNOT_FAKES
    import KnotFakes

    private struct FakeClock {
        var now = ContinuousClock.now
        mutating func advance(_ duration: Duration) { now += duration }
    }

    @MainActor
    private final class RecordingPanel: MacCapturePanel {
        let model: NoteViewModel
        let finished: CaptureState? = nil
        let isVisible = false
        var held = false
        var needsHotkey = false
        var externalProblem: SurfaceProblem?
        var stopOrStart: (() -> Void)?
        private(set) var typing: [PanelPresentation] = []
        private(set) var recording: [PanelPresentation] = []

        init(environment: AppEnvironment) {
            model = NoteViewModel(
                environment: environment,
                context: UIContext(thisDevice: environment.ids.make(), sync: .notInThisBuild),
                surface: .macPanel, announcer: RecordingAnnouncer())
        }

        func toggleTyping(_ presentation: PanelPresentation) {
            typing.append(presentation)
        }

        func showRecording(held: Bool, continuing: Bool?, presentation: PanelPresentation) {
            self.held = held
            recording.append(presentation)
        }

        func decidedDestination(_ continues: Bool) {}
        func setRecordingLive(_ live: Bool) {}
        func ended(_ state: CaptureState) {}
        func updateOutcome(_ record: NoteRecord, for capture: CaptureID) {}
    }

    struct HotkeyGestureTests {
        @Test("panel-tap-takes-the-keyboard")
        @MainActor
        func tapTakesKeyboard() async {
            var clock = FakeClock()
            var gesture = HotkeyGesture()
            #expect(gesture.receive(.keyDown(at: clock.now)) == [.prepareMicrophone])
            clock.advance(.milliseconds(249))
            let effects = gesture.release(at: clock.now)
            #expect(effects == [.releaseMicrophone, .tap])
            await withCoordinator { coordinator, panel in
                coordinator.apply(effects)
                #expect(panel.typing.map(\.takesKeyboard) == [true])
                #expect(panel.recording.isEmpty)
            }
            #expect(gesture.state == .idle)
        }

        @Test("panel-hold-does-not-take-keyboard")
        @MainActor
        func holdKeepsKeyboardInForegroundApp() async {
            var clock = FakeClock()
            var gesture = HotkeyGesture()
            let down = clock.now
            _ = gesture.receive(.keyDown(at: down))
            clock.advance(.milliseconds(250))
            let effects = gesture.receive(.markReached(forKeyDownAt: down))
            #expect(effects == [.startHoldRecording])
            await withCoordinator { coordinator, panel in
                coordinator.apply(effects)
                #expect(panel.typing.isEmpty)
                #expect(panel.recording.map(\.takesKeyboard) == [false])
            }
            #expect(gesture.release(at: clock.now) == [.stopRecording])
        }

        @MainActor
        private func withCoordinator(_ check: (MacCaptureCoordinator, RecordingPanel) -> Void) async {
            let root = FileManager.default.temporaryDirectory.appending(path: "KnotMacRules-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let environment = AppEnvironment.makePreview(root: root)
            let panel = RecordingPanel(environment: environment)
            let coordinator = MacCaptureCoordinator(panel: panel, environment: environment, onboardingDefaults: nil)
            check(coordinator, panel)
            await coordinator.stopAndSettle()
            coordinator.shutDown()
        }

        @Test
        func releaseBeatsTheDeadline() {
            var clock = FakeClock()
            var gesture = HotkeyGesture()
            let down = clock.now
            _ = gesture.receive(.keyDown(at: down))
            clock.advance(.milliseconds(250))
            #expect(gesture.release(at: clock.now) == [.startHoldRecording, .stopRecording])
            #expect(gesture.receive(.markReached(forKeyDownAt: down)).isEmpty)
        }

        @Test("hotkey-release-that-never-arrives")
        func missingRelease() {
            let down = FakeClock().now
            var gesture = HotkeyGesture()
            _ = gesture.receive(.keyDown(at: down))
            _ = gesture.receive(.markReached(forKeyDownAt: down))
            var escape = gesture
            var nextPress = gesture
            var stopButton = gesture
            #expect(escape.receive(.escape) == [.stopRecording])
            #expect(nextPress.receive(.keyDown(at: down + .seconds(1))) == [.stopRecording])
            #expect(stopButton.receive(.escape) == [.stopRecording])
            #expect(gesture.checkModifiers(required: [], held: []).isEmpty)
            #expect(gesture.checkModifiers(required: [.command, .shift], held: [.command, .shift, .control]).isEmpty)
            #expect(gesture.checkModifiers(required: [.command, .shift], held: .command) == [.stopRecording])
        }

        @Test(arguments: [Duration.milliseconds(249), .milliseconds(250)])
        @MainActor
        func preparationReleasesOnlyOnTap(_ elapsed: Duration) async throws {
            let locations = try StoreLocations.resolve(
                flavour: .dev, platform: .macOS, appContainer: FileManager.default.temporaryDirectory,
                appGroup: .absent, devStoreFolder: UUID().uuidString, environment: [:])
            let recorder = ScriptedRecorder(locations: locations, layer: PosixFileLayer(), clock: SystemWallClock())
            var preparation = HotkeyPreparation(recorder: recorder)
            var gesture = HotkeyGesture()
            let down = FakeClock().now
            for effect in gesture.receive(.keyDown(at: down)) { preparation.apply(effect) }
            for effect in gesture.release(at: down + elapsed) { preparation.apply(effect) }
            await preparation.pending?.value
            #expect(recorder.prepareCount == 1)
            #expect(recorder.releasePreparationCount == (elapsed < HotkeyMachine.holdMark ? 1 : 0))
        }

        @Test
        func onlyAnUntouchedRecordingPanelHides() {
            var panel = PanelDismissal()
            panel.show(.recording)
            #expect(panel.canAutoHide)
            panel.interacted()
            #expect(!panel.canAutoHide)
            panel.show(.typing)
            #expect(!panel.canAutoHide)
        }
    }
#endif
