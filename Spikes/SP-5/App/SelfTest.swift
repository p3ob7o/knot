import AVFoundation
import AppKit
import Carbon

/// The self-test, started by the launch argument `-SP5SelfTest` from Spikes/SP-5/build.sh.
///
/// It shows nothing and takes no focus: no status item, no window, no panel on screen, and
/// the app never activates. It never touches the microphone. It registers only keys that no
/// Apple keyboard has (F20 with modifiers), and it quits by itself within a few seconds.
@MainActor
enum SelfTest {
    /// Keys the holder process takes before the self-test runs (see `Holder`).
    static let sharedByHolder = HotKeySpec(
        keyCode: UInt32(kVK_F20), modifiers: UInt32(controlKey | optionKey | shiftKey), label: "⌃⌥⇧F20")
    static let exclusiveByHolder = HotKeySpec(
        keyCode: UInt32(kVK_F20), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey), label: "⌃⌥⇧⌘F20")
    /// The self-test's own key, which nothing else registers.
    static let own = HotKeySpec(
        keyCode: UInt32(kVK_F20), modifiers: UInt32(optionKey | shiftKey), label: "⌥⇧F20")
    static let functionAlone = HotKeySpec(keyCode: UInt32(kVK_F20), modifiers: 0, label: "F20")

    static func run() async {
        SP5Log.echo.store(true, ordering: .relaxed)
        let started = Clock.now()
        SP5Log.record("selftest.begin", ["bundle": Bundle.main.bundleIdentifier ?? "none"])

        // 1. The sandbox, read from inside the process.
        SP5Log.record(
            "selftest.sandbox",
            [
                "appSandbox": Permissions.entitlement("com.apple.security.app-sandbox"),
                "audioInput": Permissions.entitlement("com.apple.security.device.audio-input"),
                "applicationGroups": Permissions.entitlement("com.apple.security.application-groups"),
                "inContainer": String(Permissions.inContainer),
                "signing": Bundle.main.object(forInfoDictionaryKey: "KnotSigning") as? String ?? "unknown",
                "flavour": Bundle.main.object(forInfoDictionaryKey: "KnotFlavour") as? String ?? "unknown",
            ])

        // 2. What the app may do, read without asking. None of these prompts.
        let input = InputDevice.current()
        SP5Log.record(
            "selftest.permissions",
            [
                "listenPreflight": String(Permissions.listenPreflight),
                "listenAccess": Permissions.listenAccess,
                "postPreflight": String(Permissions.postPreflight),
                "secureInput": String(Permissions.secureInput),
                "microphone": Microphone.authorization,
                "defaultInputPresent": String(input.present),
                "defaultInputWired": String(InputDevice.isWired(input.transport)),
                "activationPolicy": NSApp.activationPolicy() == .accessory ? "accessory" : "other",
                "appActive": String(NSApp.isActive),
            ])

        // 3. Carbon registration in the sandbox.
        let center = HotKeyCenter.shared
        let handler = center.installHandler()
        let ownStatus = center.register(own, id: 11, exclusive: false)
        let again = center.register(own, id: 12, exclusive: false)
        let functionStatus = center.register(functionAlone, id: 13, exclusive: false)
        let exclusiveOwn = center.register(own, id: 14, exclusive: true)
        SP5Log.record(
            "selftest.register",
            [
                "handler": String(handler), "own": String(ownStatus), "sameKeySecondID": String(again),
                "functionKeyNoModifier": String(functionStatus), "ownExclusiveWhileShared": String(exclusiveOwn),
            ])
        for id in [UInt32(11), 12, 13, 14] { center.unregister(id: id) }

        // 4. Against another process: the holder (started first by build.sh) holds one key shared
        // and one exclusively.
        let holderRunning = CommandLine.arguments.contains("-SP5HolderRunning")
        let exclusiveOverShared = center.register(sharedByHolder, id: 21, exclusive: true)
        center.unregister(id: 21)
        let exclusiveOverExclusive = center.register(exclusiveByHolder, id: 22, exclusive: true)
        center.unregister(id: 22)
        let sharedOverExclusive = center.register(exclusiveByHolder, id: 23, exclusive: false)
        center.unregister(id: 23)
        SP5Log.record(
            "selftest.other-process",
            [
                "holderRunning": String(holderRunning),
                "exclusiveOverShared": String(exclusiveOverShared),
                "exclusiveOverExclusive": String(exclusiveOverExclusive),
                "sharedOverExclusive": String(sharedOverExclusive),
            ])

        // 5. The handler and the machine, driven by events sent to the app's own target. The
        // controller is headless: it records the machine's effects and performs none.
        let model = SpikeModel()
        let controller = PressController(model: model, headless: true)
        _ = center.register(own, id: PressController.hotKeyID, exclusive: false)
        _ = center.sendSynthetic(.pressed, id: PressController.hotKeyID)
        try? await Task.sleep(for: .milliseconds(100))
        _ = center.sendSynthetic(.released, id: PressController.hotKeyID)
        try? await Task.sleep(for: .milliseconds(50))
        _ = center.sendSynthetic(.pressed, id: PressController.hotKeyID)
        try? await Task.sleep(for: .milliseconds(450))
        _ = center.sendSynthetic(.released, id: PressController.hotKeyID)
        try? await Task.sleep(for: .milliseconds(50))
        center.unregister(id: PressController.hotKeyID)
        let kinds = model.records.reversed().map { "\($0.kind.rawValue)\($0.synthetic ? "" : "(not synthetic)")" }
        let marks = model.records.compactMap(\.markLateMS).map { String(format: "%.1f", $0) }
        SP5Log.record(
            "selftest.synthetic",
            [
                "records": kinds.joined(separator: ","), "markLateMS": marks.joined(separator: ","),
                "effects": controller.effectsLog.joined(separator: ","),
            ])

        // 6. The machine alone, from a table.
        let (passed, failed) = MachineTable.run()
        SP5Log.record("selftest.machine", ["passed": String(passed), "failed": failed.joined(separator: ";")])

        // 7. The panel variants, built and never shown.
        for behaviour in PanelBehaviour.allCases {
            let panel = CapturePanel()
            panel.apply(behaviour)
            var fields = panel.describe()
            fields["variant"] = String(behaviour.rawValue.prefix(1))
            SP5Log.record("selftest.panel", fields)
        }

        SP5Log.record(
            "selftest.end",
            [
                "seconds": String(format: "%.2f", Clock.now() - started),
                "microphoneTouched": "false", "panelShown": "false", "appActive": String(NSApp.isActive),
            ])
    }
}

/// The holder, started by build.sh before the self-test with `-SP5HoldKeys`: another sandboxed
/// process that holds one key shared and one exclusively, for a few seconds, then quits.
@MainActor
enum Holder {
    static func run() {
        SP5Log.echo.store(true, ordering: .relaxed)
        let center = HotKeyCenter.shared
        _ = center.installHandler()
        let shared = center.register(SelfTest.sharedByHolder, id: 31, exclusive: false)
        let exclusive = center.register(SelfTest.exclusiveByHolder, id: 32, exclusive: true)
        SP5Log.record("holder.registered", ["shared": String(shared), "exclusive": String(exclusive)])
    }
}

/// The tap/hold machine against a table of presses. Times in seconds from key-down.
enum MachineTable {
    struct Case {
        var name: String
        var mode: MicrophoneMode = .atMark
        var panelShowing = false
        var steps: [Step]
        var expected: [PressEffect]
    }

    enum Step {
        case down(Double)
        case up(Double)
        case mark(Double)
        case keyState(Bool, Double)
        case escape
    }

    static let cases: [Case] = [
        Case(
            name: "tap 100 ms", steps: [.down(0), .up(0.1)],
            expected: [.prepareMicrophone, .discardMicrophone, .showPanelForTyping]),
        Case(
            name: "tap 249 ms", steps: [.down(0), .up(0.249)],
            expected: [.prepareMicrophone, .discardMicrophone, .showPanelForTyping]),
        Case(
            name: "tap hides a showing panel", panelShowing: true, steps: [.down(0), .up(0.1)],
            expected: [.prepareMicrophone, .discardMicrophone, .hidePanel]),
        Case(
            name: "hold 2 s", steps: [.down(0), .mark(0.25), .up(2)],
            expected: [
                .prepareMicrophone, .showPanelListening, .openMicrophone, .armEscape, .stopRecording(.released),
                .disarmEscape,
            ]),
        Case(
            name: "released at 260 ms before a late timer", steps: [.down(0), .up(0.26), .mark(0.27)],
            expected: [
                .prepareMicrophone, .showPanelListening, .openMicrophone, .armEscape, .stopRecording(.released),
                .disarmEscape,
            ]),
        Case(
            name: "timer early by 10 ms does nothing", steps: [.down(0), .mark(0.24), .up(0.245)],
            expected: [.prepareMicrophone, .discardMicrophone, .showPanelForTyping]),
        Case(
            name: "missed release, key state up",
            steps: [.down(0), .mark(0.25), .keyState(true, 1.25), .keyState(false, 2.25)],
            expected: [
                .prepareMicrophone, .showPanelListening, .openMicrophone, .armEscape, .stopRecording(.keyStateUp),
                .disarmEscape,
            ]),
        Case(
            name: "missed release, Esc", steps: [.down(0), .mark(0.25), .escape],
            expected: [
                .prepareMicrophone, .showPanelListening, .openMicrophone, .armEscape, .stopRecording(.escape),
                .disarmEscape,
            ]),
        Case(
            name: "missed release, second press, its release swallowed",
            steps: [.down(0), .mark(0.25), .down(5), .up(5.1)],
            expected: [
                .prepareMicrophone, .showPanelListening, .openMicrophone, .armEscape,
                .stopRecording(.pressedAgain), .disarmEscape,
            ]),
        Case(
            name: "repeat while down is ignored", steps: [.down(0), .down(0.05), .up(0.1)],
            expected: [.prepareMicrophone, .discardMicrophone, .showPanelForTyping]),
        Case(
            name: "key-down mode: tap discards", mode: .atKeyDown, steps: [.down(0), .up(0.1)],
            expected: [.prepareMicrophone, .openMicrophone, .discardMicrophone, .showPanelForTyping]),
        Case(
            name: "key-down mode: hold", mode: .atKeyDown, steps: [.down(0), .mark(0.25), .up(1)],
            expected: [
                .prepareMicrophone, .openMicrophone, .showPanelListening, .armEscape, .stopRecording(.released),
                .disarmEscape,
            ]),
        Case(
            name: "key state down keeps recording", steps: [.down(0), .mark(0.25), .keyState(true, 1.25), .up(1.5)],
            expected: [
                .prepareMicrophone, .showPanelListening, .openMicrophone, .armEscape, .stopRecording(.released),
                .disarmEscape,
            ]),
    ]

    static func run() -> (Int, [String]) {
        var passed = 0
        var failed: [String] = []
        for test in cases {
            var machine = PressMachine()
            machine.mode = test.mode
            machine.panelShowing = test.panelShowing
            var effects: [PressEffect] = []
            for step in test.steps {
                switch step {
                case .down(let t): effects += machine.keyDown(at: t)
                case .up(let t): effects += machine.keyUp(at: t)
                case .mark(let t): effects += machine.markReached(at: t)
                case .keyState(let down, let t): effects += machine.keyState(isDown: down, at: t)
                case .escape: effects += machine.escape()
                }
            }
            if effects == test.expected && machine.phase == .idle {
                passed += 1
            } else {
                failed.append("\(test.name): \(effects) phase \(machine.phase)")
            }
        }
        return (passed, failed)
    }
}
