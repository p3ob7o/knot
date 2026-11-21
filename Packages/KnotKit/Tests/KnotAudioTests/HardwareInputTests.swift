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

    /// A tap's buffer becomes one channel, the mean of its channels, in the working file's
    /// format; another rate is refused. The engine delivers one buffer per channel.
    @Test func aTapBufferIsMixedDownToOneChannel() throws {
        let mono = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let stereo = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 4))
        buffer.frameLength = 4
        let channels = try #require(buffer.floatChannelData)
        for (frame, (left, right)) in zip(Self.left, Self.right).enumerated() {
            channels[0][frame] = left
            channels[1][frame] = right
        }
        let mixed = try #require(Downmix.mono(AVReadOnlyAudioPCMBuffer(copying: buffer), into: mono))
        #expect(mixed.format == mono && Levels.floats(of: mixed) == Self.mean)

        let other = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false))
        let elsewhere = try #require(AVAudioPCMBuffer(pcmFormat: other, frameCapacity: 4))
        elsewhere.frameLength = 4
        #expect(Downmix.mono(AVReadOnlyAudioPCMBuffer(copying: elsewhere), into: mono) == nil)
    }

    /// Every layout of a buffer list mixes to the same mean: one buffer per channel, one buffer
    /// that interleaves both, in floats and in 16-bit integers. A list that does not hold its
    /// channels, or holds fewer frames than asked, is refused and nothing is read.
    ///
    /// These lists are made by hand. On the hosted runner's macOS 27.0.1, an interleaved stereo
    /// buffer written through `AVAudioPCMBuffer` and copied with
    /// `AVReadOnlyAudioPCMBuffer(copying:)` mixed to [0.375, 0, 0.5, 0], where macOS 27.3 gives
    /// the mean: not all the samples written reached the copy there.
    @Test func everyLayoutMixesToTheMean() {
        let interleaved = zip(Self.left, Self.right).flatMap { [$0, $1] }
        #expect(Self.mix([interleaved], channelsPerBuffer: 2) == Self.mean)
        #expect(Self.mix([Self.left, Self.right], channelsPerBuffer: 1) == Self.mean)
        let integers = interleaved.map { Int16($0 * 16_384) }
        #expect(Self.mix(integers: integers, channels: 2) == Self.mean.map { $0 / 2 })
        #expect(Self.mix([interleaved], channelsPerBuffer: 2, channels: 3) == nil, "Two channels are not three.")
        #expect(Self.mix([interleaved], channelsPerBuffer: 2, frames: 5) == nil, "Four frames are not five.")
    }

    static let left: [Float] = [0.5, -0.5, 1, 0]
    static let right: [Float] = [0.25, 0.5, -1, 0.75]
    static let mean: [Float] = [0.375, 0, 0, 0.375]

    /// Mixes float buffers laid out as given, through a buffer list made by hand over memory
    /// that lives for the whole call.
    static func mix(_ buffers: [[Float]], channelsPerBuffer: Int, channels: Int = 2, frames: Int = 4) -> [Float]? {
        let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
        let memory = buffers.map { samples -> UnsafeMutableBufferPointer<Float> in
            let memory = UnsafeMutableBufferPointer<Float>.allocate(capacity: samples.count)
            _ = memory.initialize(from: samples)
            return memory
        }
        defer {
            for samples in memory { samples.deallocate() }
            free(list.unsafeMutablePointer)
        }
        for (index, samples) in memory.enumerated() {
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(channelsPerBuffer),
                mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(samples.baseAddress))
        }
        var output = [Float](repeating: 9, count: frames)
        let mixed = output.withUnsafeMutableBufferPointer { out in
            Downmix.mix(
                list.unsafePointer, frames: frames, channels: channels, commonFormat: .pcmFormatFloat32,
                into: out.baseAddress!)
        }
        return mixed ? output : nil
    }

    /// Mixes one interleaved buffer of 16-bit integers through a buffer list made by hand.
    static func mix(integers: [Int16], channels: Int) -> [Float]? {
        var samples = integers
        var output = [Float](repeating: 9, count: integers.count / channels)
        let frames = output.count
        return samples.withUnsafeMutableBytes { bytes -> [Float]? in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels), mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            let mixed = output.withUnsafeMutableBufferPointer { out in
                Downmix.mix(
                    &list, frames: frames, channels: channels, commonFormat: .pcmFormatInt16, into: out.baseAddress!)
            }
            return mixed ? output : nil
        }
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
