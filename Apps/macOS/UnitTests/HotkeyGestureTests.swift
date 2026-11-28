import Foundation
import KnotCore
import Testing

#if DEBUG || KNOT_FAKES
    import KnotFakes

    private struct FakeClock {
        var now = ContinuousClock.now
        mutating func advance(_ duration: Duration) { now += duration }
    }

    struct HotkeyGestureTests {
        @Test("panel-tap-takes-the-keyboard")
        func tapTakesKeyboard() {
            var clock = FakeClock()
            var gesture = HotkeyGesture()
            #expect(gesture.receive(.keyDown(at: clock.now)) == [.prepareMicrophone])
            clock.advance(.milliseconds(249))
            let effects = gesture.release(at: clock.now)
            #expect(effects == [.releaseMicrophone, .tap])
            #expect(effects.compactMap(\.panelPresentation).map(\.takesKeyboard) == [true])
            #expect(gesture.state == .idle)
        }

        @Test("panel-hold-does-not-take-keyboard")
        func holdKeepsKeyboardInForegroundApp() {
            var clock = FakeClock()
            var gesture = HotkeyGesture()
            let down = clock.now
            _ = gesture.receive(.keyDown(at: down))
            clock.advance(.milliseconds(250))
            let effects = gesture.receive(.markReached(forKeyDownAt: down))
            #expect(effects == [.startHoldRecording])
            #expect(effects.compactMap(\.panelPresentation).map(\.takesKeyboard) == [false])
            #expect(gesture.release(at: clock.now) == [.stopRecording])
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
