import AVFAudio
import Foundation
import KnotCore
import KnotTestSupport
import Synchronization
import Testing

@testable import KnotAudio

/// Under test the recorder refuses the hardware input, and no test here opens one: each test
/// that reaches the microphone input passes it a stand-in for the hardware that records every
/// use and opens nothing.
@Suite struct HardwareInputTests {
    /// This process is a test's, so the microphone may not open in it.
    @Test func thisTestProcessMayNotOpenAHardwareInput() {
        #expect(HardwareInputPolicy.refusalForThisProcess() != nil)
    }

    /// Each sign of a test, an agent or a simulator refuses on its own; a process with none of
    /// them may open the input.
    @Test(arguments: [
        (Signs(isSimulator: true), HardwareInputPolicy.Refusal?.some(.simulator)),
        (Signs(environment: ["KNOT_AGENT": "1"]), .agent),
        (Signs(environment: ["XCTestConfigurationFilePath": "/x"]), .test),
        (Signs(environment: ["XCTestBundlePath": "/x"]), .test),
        (Signs(environment: ["XCTestSessionIdentifier": "x"]), .test),
        (Signs(processName: "xctest"), .test),
        (Signs(processName: "swiftpm-testing-helper"), .test),
        (Signs(bundles: ["/Build/KnotKitPackageTests.xctest"]), .test),
        (Signs(environment: ["KNOT_AGENT": "0"], bundles: ["/Applications/Knot.app"]), nil),
        (Signs(), nil),
    ])
    func eachSignRefusesOnItsOwn(signs: Signs, refusal: HardwareInputPolicy.Refusal?) {
        #expect(HardwareInputPolicy.refusal(for: signs.process) == refusal)
    }

    /// A refused input touches nothing: no permission is asked, no session made ready, no engine
    /// made, and the start says there is no input device.
    @Test func aRefusedMicrophoneTouchesNoHardware() async {
        let hardware = StandInHardware()
        let input = MicrophoneInput(hardware: hardware, policy: { .test })
        let error = await #expect(throws: KnotError.self) { try await input.open() }
        #expect(error?.code == KnotError.noInputDevice.code)
        #expect(hardware.uses.isEmpty, "The hardware was used: \(hardware.uses)")
    }

    /// Where the input may open, a permission refused stops it there, and a session that cannot
    /// be made ready stops it before the engine.
    @Test func theMicrophoneAsksInOrder() async {
        let refused = StandInHardware(permission: false)
        let first = await #expect(throws: KnotError.self) {
            try await MicrophoneInput(hardware: refused, policy: { nil }).open()
        }
        #expect(first?.code == KnotError.microphonePermissionRefused.code && refused.uses == ["permission"])

        let busy = StandInHardware(permission: true, session: .audioSessionBusy)
        let second = await #expect(throws: KnotError.self) {
            try await MicrophoneInput(hardware: busy, policy: { nil }).open()
        }
        #expect(second?.code == KnotError.audioSessionBusy.code && busy.uses == ["permission", "activate"])
    }

    /// The live entry point that knows the store's locations gives the live recorder on the
    /// microphone input, which asks the policy; the one without leaves the port as it was.
    @Test func theLiveEntryPointWiresTheRecorderOnTheMicrophone() throws {
        let folder = try ScratchFolder()
        let wired = KnotAudioLive.wire(.unavailable, locations: folder.locations)
        let recorder = try #require(wired.recorder as? LiveRecorder)
        #expect(recorder.locations == folder.locations)
        let input = try #require(recorder.input as? MicrophoneInput)
        #expect(input.hardware is SystemHardwareAudio && input.policy() != nil)
        #expect(KnotAudioLive.wire(.unavailable).recorder is UnavailableRecorder)
    }

    /// A tap's buffer of any channel count becomes one channel, the mean of its channels, in
    /// the working file's format; another rate is refused.
    @Test func aTapBufferIsMixedDownToOneChannel() throws {
        let mono = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        for interleaved in [false, true] {
            let stereo = try #require(
                AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: interleaved))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 4))
            buffer.frameLength = 4
            let left: [Float] = [0.5, -0.5, 1, 0]
            let right: [Float] = [0.25, 0.5, -1, 0.75]
            let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for frame in 0..<4 {
                if interleaved {
                    let data = list[0].mData!.assumingMemoryBound(to: Float.self)
                    data[frame * 2] = left[frame]
                    data[frame * 2 + 1] = right[frame]
                } else {
                    list[0].mData!.assumingMemoryBound(to: Float.self)[frame] = left[frame]
                    list[1].mData!.assumingMemoryBound(to: Float.self)[frame] = right[frame]
                }
            }
            let mixed = try #require(Downmix.mono(AVReadOnlyAudioPCMBuffer(copying: buffer), into: mono))
            #expect(mixed.format == mono && Levels.floats(of: mixed) == [0.375, 0, 0, 0.375])
        }
        let other = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false))
        let elsewhere = try #require(AVAudioPCMBuffer(pcmFormat: other, frameCapacity: 4))
        elsewhere.frameLength = 4
        #expect(Downmix.mono(AVReadOnlyAudioPCMBuffer(copying: elsewhere), into: mono) == nil)
    }

    /// The signs of a process, for the policy's table.
    struct Signs: Sendable, CustomTestStringConvertible {
        var environment: [String: String] = [:]
        var bundles: [String] = ["/Applications/Knot.app"]
        var processName = "Knot"
        var isSimulator = false

        var process: HardwareInputPolicy.Process {
            HardwareInputPolicy.Process(
                environment: environment, bundlePaths: bundles, processName: processName, isSimulator: isSimulator)
        }

        var testDescription: String { "\(environment) \(bundles) \(processName) simulator \(isSimulator)" }
    }
}

/// Hardware that opens nothing: it records each use and answers as it was told, and it never
/// makes an engine.
final class StandInHardware: HardwareAudio {
    private let permission: Bool
    private let session: KnotError?
    private let used = Mutex<[String]>([])

    var uses: [String] { used.withLock { $0 } }

    init(permission: Bool = false, session: KnotError? = nil) {
        self.permission = permission
        self.session = session
    }

    func recordPermission() async -> Bool {
        used.withLock { $0.append("permission") }
        return permission
    }

    func activateSession() throws(KnotError) {
        used.withLock { $0.append("activate") }
        if let session { throw session }
    }

    func deactivateSession() {
        used.withLock { $0.append("deactivate") }
    }

    func makeEngine() throws(KnotError) -> AVAudioEngine {
        used.withLock { $0.append("engine") }
        throw KnotError.noInputDevice
    }
}
