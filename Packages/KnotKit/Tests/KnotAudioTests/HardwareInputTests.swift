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

    /// An interleaved stereo buffer, made the way a tap's is, goes through `Downmix.mono` and
    /// mixes to the mean. Each step is checked on the way and its count of right frames printed:
    /// the samples written into the buffer, the system's read-only copy of it, the mix. Where the
    /// system's copy does not hold what it was given, that is recorded as a known issue of that
    /// system, by its version, and the mix is not judged on it. Where the copy is whole and the mix
    /// is wrong, the test fails.
    @Test(arguments: [16_000.0, 44_100.0, 48_000.0])
    func anInterleavedTapBufferIsMixedDown(rate: Double) throws {
        let stereo = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: true))
        let mono = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 4))
        buffer.frameLength = 4
        let written = zip(Self.left, Self.right).flatMap { [$0, $1] }
        let data = try #require(buffer.mutableAudioBufferList.pointee.mBuffers.mData)
            .assumingMemoryBound(to: Float.self)
        for (index, sample) in written.enumerated() { data[index] = sample }
        let source = Self.rightFrames(Array(UnsafeBufferPointer(start: data, count: written.count)), written)
        let copy = AVReadOnlyAudioPCMBuffer(copying: buffer)
        let copied = copy.withUnsafeAudioBufferList { list -> [Float] in
            guard list.pointee.mNumberBuffers == 1, let bytes = list.pointee.mBuffers.mData else { return [] }
            let count = min(Int(list.pointee.mBuffers.mDataByteSize) / MemoryLayout<Float>.size, written.count)
            return Array(UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: Float.self), count: count))
        }
        let inCopy = Self.rightFrames(copied, written)
        let mixed = Downmix.mono(copy, into: mono).map(Levels.floats(of:)) ?? []
        let inMix = zip(mixed, Self.mean).filter { $0 == $1 }.count
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        print(
            "interleaved-copy rate \(Int(rate)) on \(system): frames right, source \(source)/4, copy \(inCopy)/4, mix \(inMix)/4"
        )
        #expect(source == 4, "The buffer holds what was written into it.")
        guard inCopy == 4 else {
            withKnownIssue("On \(system) the system's copy of an interleaved buffer holds \(inCopy) of 4 frames.") {
                Issue.record("The copy lost frames before the mix-down: \(inCopy) of 4 are right.")
            }
            return
        }
        #expect(mixed == Self.mean, "The copy is whole and the mix-down is wrong: \(inMix) of 4 frames are right.")
    }

    /// How many of the frames of an interleaved stereo `found` equal those of `expected`.
    static func rightFrames(_ found: [Float], _ expected: [Float]) -> Int {
        stride(from: 0, to: expected.count, by: 2).filter { start in
            start + 1 < found.count && found[start] == expected[start] && found[start + 1] == expected[start + 1]
        }.count
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

    /// A stop that arrives while the start runs, at either point, takes the tap away and stops
    /// the engine if the start put them there, once the start is over and before the stop
    /// returns. The stop is asked for from inside the start, by a hook, and the start goes on only
    /// once it has been asked for: either by a stop of the recording or by the tap's ending.
    @Test(arguments: [Inside.tapByStop, .tapByEnding, .startByStop])
    func aStopDuringTheStartLeavesNothingRunning(inside: Inside) async throws {
        let (opened, engine, hardware) = try await Self.openStandIn()
        let stopping = StopTask()
        let wrongRate = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false))
        engine.whenAt(inside == .startByStop ? .starting : .installingTheTap) { engine in
            if inside == .tapByEnding, let buffer = Self.silence(wrongRate) {
                // A buffer the file cannot take: the tap ends the recording, which stops the input.
                engine.deliver(buffer)
            } else {
                stopping.start { await opened.stop() }
            }
            Self.waitUntil { opened.stopRequested }
        }
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        try opened.start(format: format) { delivery in
            if case .ended = delivery { stopping.start { await opened.stop() } }
        }
        await stopping.wait()
        let expected =
            inside == .startByStop ? ["installTap", "start", "stop", "removeTap"] : ["installTap", "removeTap"]
        #expect(engine.calls == expected, "\(engine.calls)")
        await opened.stop()
        #expect(engine.calls == expected, "A second stop does nothing more.")
        #expect(hardware.uses.filter { $0 == "deactivate" }.count == 1, "\(hardware.uses)")
    }

    /// The check for an input reads the hardware's format, the input node's input format, as
    /// the SDK says: an input with no channel or no rate is no input device, whatever the tap
    /// says, and so is a tap with no rate. The session is given back.
    @Test(arguments: [
        (InputShape(sampleRate: 48_000, channels: 0), InputShape(sampleRate: 48_000, channels: 1)),
        (InputShape(sampleRate: 0, channels: 1), InputShape(sampleRate: 48_000, channels: 1)),
        (InputShape(sampleRate: 48_000, channels: 1), InputShape(sampleRate: 0, channels: 1)),
    ])
    func anInputWithNoHardwareIsNoInputDevice(hardware shape: InputShape, tap: InputShape) async {
        let hardware = StandInHardware(permission: true, engine: StandInEngine(tap: tap, hardware: shape))
        let error = await #expect(throws: KnotError.self) {
            try await MicrophoneInput(hardware: hardware, policy: { nil }).open()
        }
        #expect(error?.code == KnotError.noInputDevice.code)
        #expect(hardware.uses == ["permission", "activate", "engine", "deactivate"], "\(hardware.uses)")
    }

    /// The session's errors are told by what they say: no input hardware is `no_input_device`,
    /// and the rest, a call holding the audio among them, `audio_session_busy`, with the code.
    @Test func theSessionsErrorsAreToldApart() {
        let noInput = SessionError.knotError(code: 0x2172_6573)  // '!res'
        #expect(noInput.code == KnotError.noInputDevice.code && noInput.context.engineCode == 0x2172_6573)
        for code in [0x2170_7269, 0x7768_6174, 0x2172_6563, -50] {  // '!pri', 'what', '!rec', bad parameter
            #expect(SessionError.knotError(code: code).code == KnotError.audioSessionBusy.code)
        }
    }

    /// A stop that came before the start leaves nothing to start: no tap, no engine.
    @Test func aStopBeforeTheStartLeavesNothingToStart() async throws {
        let (opened, engine, _) = try await Self.openStandIn()
        await opened.stop()
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        try opened.start(format: format) { _ in }
        #expect(engine.calls.isEmpty, "\(engine.calls)")
    }

    /// A stop after a start that ran whole stops the engine and takes the tap away, once.
    @Test func aStopAfterTheStartLeavesNothingRunning() async throws {
        let (opened, engine, _) = try await Self.openStandIn()
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        try opened.start(format: format) { _ in }
        await opened.stop()
        await opened.stop()
        #expect(engine.calls == ["installTap", "start", "stop", "removeTap"], "\(engine.calls)")
    }

    enum Inside: String, Sendable {
        case tapByStop
        case tapByEnding
        case startByStop
    }

    /// The microphone opened on a stand-in engine at 48 kHz, which opens nothing.
    static func openStandIn() async throws -> (OpenMicrophone, StandInEngine, StandInHardware) {
        let engine = StandInEngine(tap: InputShape(sampleRate: 48_000, channels: 1))
        let hardware = StandInHardware(permission: true, engine: engine)
        let opened = try await MicrophoneInput(hardware: hardware, policy: { nil }).open()
        return (try #require(opened as? OpenMicrophone), engine, hardware)
    }

    /// 1,600 frames of silence in `format`.
    static func silence(_ format: AVAudioFormat) -> AVReadOnlyAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600) else { return nil }
        buffer.frameLength = 1_600
        return AVReadOnlyAudioPCMBuffer(copying: buffer)
    }

    /// Blocks the calling thread until `condition` holds, for at most `SuiteWait.limit`.
    static func waitUntil(_ condition: () -> Bool) {
        let deadline = ContinuousClock.now + SuiteWait.limit
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Waited \(SuiteWait.limit) inside the start.")
                return
            }
            usleep(500)
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

/// One stop, run in a task of its own the first time it is asked for, and waited for.
final class StopTask: Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)

    func start(_ body: @escaping @Sendable () async -> Void) {
        task.withLock { task in
            if task == nil { task = Task { await body() } }
        }
    }

    func wait() async {
        let task = task.withLock { $0 }
        if let task {
            _ = await SuiteWait.value("the stop") { await task.value }
        } else {
            Issue.record("No stop was asked for.")
        }
    }
}

/// Hardware that opens nothing: it records each use and answers as it was told, and it never
/// makes a real engine.
final class StandInHardware: HardwareAudio {
    private let permission: Bool
    private let session: KnotError?
    private let engine: StandInEngine?
    private let used = Mutex<[String]>([])

    var uses: [String] { used.withLock { $0 } }

    /// With no `engine`, making one fails, as it does when there is no input.
    init(permission: Bool = false, session: KnotError? = nil, engine: StandInEngine? = nil) {
        self.permission = permission
        self.session = session
        self.engine = engine
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

    func makeEngine() throws(KnotError) -> any InputEngine {
        used.withLock { $0.append("engine") }
        guard let engine else { throw KnotError.noInputDevice }
        return engine
    }
}

/// An engine that opens nothing. It records each call, and runs a hook inside the tap's
/// installation or inside the start, so that a test delivers an ending at that point.
final class StandInEngine: InputEngine {
    enum Point: Sendable {
        case installingTheTap
        case starting
    }

    let tap: InputShape
    let hardware: InputShape
    private let state = Mutex<(calls: [String], tap: (@Sendable (AVReadOnlyAudioPCMBuffer) -> Void)?)>(([], nil))
    private let hook = Mutex<(point: Point, run: @Sendable (StandInEngine) -> Void)?>(nil)

    init(tap: InputShape, hardware: InputShape? = nil) {
        self.tap = tap
        self.hardware = hardware ?? tap
    }

    var calls: [String] { state.withLock { $0.calls } }

    /// Runs `body` inside the call at `point`, before that call returns.
    func whenAt(_ point: Point, _ body: @escaping @Sendable (StandInEngine) -> Void) {
        hook.withLock { $0 = (point, body) }
    }

    /// Hands the installed tap a buffer, as the input would.
    func deliver(_ buffer: AVReadOnlyAudioPCMBuffer) {
        let tap = state.withLock { $0.tap }
        tap?(buffer)
    }

    func installTap(bufferSize: AVAudioFrameCount, _ tap: @escaping @Sendable (AVReadOnlyAudioPCMBuffer) -> Void)
        throws(KnotError)
    {
        state.withLock {
            $0.calls.append("installTap")
            $0.tap = tap
        }
        run(at: .installingTheTap)
    }

    func removeTap() {
        state.withLock {
            $0.calls.append("removeTap")
            $0.tap = nil
        }
    }

    func start() throws(KnotError) {
        state.withLock { $0.calls.append("start") }
        run(at: .starting)
    }

    func stop() {
        state.withLock { $0.calls.append("stop") }
    }

    func configurationChanges() -> AsyncStream<Void> {
        AsyncStream { _ in }
    }

    private func run(at point: Point) {
        let body = hook.withLock { hook -> (@Sendable (StandInEngine) -> Void)? in
            guard let hook, hook.point == point else { return nil }
            return hook.run
        }
        body?(self)
    }
}
