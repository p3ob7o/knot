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
    /// the samples written into the buffer, the system's read-only copy of it, the mix.
    ///
    /// One system is known to lose part of the copy: macOS 27.0.1, whose copy of this buffer
    /// keeps two of its four frames. There, and for that loss only, the loss is a known issue, and
    /// the mix must still be right on every frame the copy kept. On any other system, and for any
    /// other loss, a short copy fails the test, as a wrong mix of a whole copy does. After finding
    /// 25.
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
            #if os(macOS)
                let version = ProcessInfo.processInfo.operatingSystemVersion
                let knownSystem = version.majorVersion == 27 && version.minorVersion == 0 && version.patchVersion == 1
            #else
                let knownSystem = false
            #endif
            guard knownSystem, inCopy == 2 else {
                Issue.record("On \(system) the system's copy holds \(inCopy) of 4 frames: no known issue covers it.")
                return
            }
            withKnownIssue("On macOS 27.0.1 the system's copy of an interleaved buffer keeps 2 of 4 frames.") {
                Issue.record("The copy lost frames before the mix-down: \(inCopy) of 4 are right.")
            }
            let kept = Self.rightFrameIndices(copied, written)
            #expect(
                kept.allSatisfy { $0 < mixed.count && mixed[$0] == Self.mean[$0] },
                "The mix is wrong on a frame the copy kept: kept \(kept), mixed \(mixed).")
            return
        }
        #expect(mixed == Self.mean, "The copy is whole and the mix-down is wrong: \(inMix) of 4 frames are right.")
    }

    /// How many of the frames of an interleaved stereo `found` equal those of `expected`.
    static func rightFrames(_ found: [Float], _ expected: [Float]) -> Int {
        rightFrameIndices(found, expected).count
    }

    /// The frames of an interleaved stereo `found` that equal those of `expected`, by index.
    static func rightFrameIndices(_ found: [Float], _ expected: [Float]) -> [Int] {
        stride(from: 0, to: expected.count, by: 2).filter { start in
            start + 1 < found.count && found[start] == expected[start] && found[start + 1] == expected[start + 1]
        }.map { $0 / 2 }
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
        // The hook holds the start's thread while it waits for the stop: off the cooperative pool,
        // so that the stop's task always has a thread to run on, however busy the pool is.
        try await Self.startOffThePool(opened, format: format) { delivery in
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

    /// A second stop, asked for while the engine's stop runs, returns only once the tap is gone,
    /// the engine stopped and the session given back, and no buffer comes through after it: in
    /// the start's undoing, the first stop having come inside the engine's start, and in the first
    /// stop's own finishing, after the start. The engine's stop holds until the second stop waits,
    /// or returns. After finding 22.
    @Test(arguments: [true, false])
    func aSecondStopWaitsForTheFirst(duringTheStart: Bool) async throws {
        let (opened, engine, hardware) = try await Self.openStandIn()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let first = StopTask()
        let second = StopTask()
        let returned = Flag()
        let seen = Mutex<(calls: [String], released: Int)>(([], 0))
        let deliveries = Mutex(0)
        if duringTheStart {
            engine.whenAt(.starting) { _ in
                first.start { await opened.stop() }
                Self.waitUntil { opened.stopRequested }
            }
        }
        engine.whenAt(.stopping) { engine in
            second.start {
                await opened.stop()
                seen.withLock { $0 = (engine.calls, hardware.uses.filter { $0 == "deactivate" }.count) }
                if let buffer = Self.silence(format) { engine.deliver(buffer) }
                returned.set()
            }
            // The first stop waits for the start too when it came inside it: the second is one more.
            let waiting = duringTheStart ? 2 : 1
            Self.waitUntil { returned.value || opened.suspendedStops >= waiting }
        }
        try await Self.startOffThePool(opened, format: format) { _ in deliveries.withLock { $0 += 1 } }
        if !duringTheStart { first.start(offThePool: true) { await opened.stop() } }
        await first.wait()
        await second.wait()
        #expect(deliveries.withLock { $0 } == 0, "A buffer came through after a stop returned.")
        #expect(seen.withLock { $0.calls } == ["installTap", "start", "stop", "removeTap"], "\(seen.withLock { $0 })")
        #expect(seen.withLock { $0.released } == 1, "The second stop returned before the session was given back.")
        #expect(hardware.uses.filter { $0 == "deactivate" }.count == 1)
    }

    /// No delivery begins once the input is finishing. A buffer that the tap hands over from
    /// inside the teardown, the stop begun and the tap still installed, and one that the removed
    /// tap hands over once the stop has returned, as a callback late on the engine's thread would,
    /// never reach the handler. One before the stop does. After finding 32.
    @Test func noDeliveryBeginsOnceTheInputIsFinishing() async throws {
        let (opened, engine, _) = try await Self.openStandIn()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(Self.silence(format))
        let deliveries = Mutex(0)
        engine.whenAt(.stopping) { engine in engine.deliver(buffer) }
        try await Self.startOffThePool(opened, format: format) { _ in deliveries.withLock { $0 += 1 } }
        engine.deliver(buffer)
        #expect(deliveries.withLock { $0 } == 1, "A buffer before the stop reaches the handler.")
        await opened.stop()
        #expect(deliveries.withLock { $0 } == 1, "A buffer the tap handed over inside the teardown was delivered.")
        engine.deliverLate(buffer)
        #expect(deliveries.withLock { $0 } == 1, "A buffer handed over after the stop was delivered.")
        #expect(engine.calls == ["installTap", "start", "stop", "removeTap"])
    }

    /// A stop returns only once a delivery under way has ended: here the interruption's, which
    /// asks for the stop and runs on after it. The delivery holds until the stop waits for it, or
    /// returns. After finding 23.
    ///
    /// The delivery holds on the input's own queue for an event of the session, and the stop runs
    /// on a queue of its own: neither wait holds a thread of the cooperative pool.
    @Test func aStopWaitsForTheDeliveryUnderWay() async throws {
        let (opened, engine, hardware) = try await Self.openStandIn()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let stopped = StopTask()
        let delivering = Mutex(false)
        let deliveringAtReturn = Mutex<Bool?>(nil)
        let returned = Flag()
        try await Self.startOffThePool(opened, format: format) { delivery in
            guard case .ended = delivery else { return }
            delivering.withLock { $0 = true }
            stopped.start(offThePool: true) {
                await opened.stop()
                deliveringAtReturn.withLock { $0 = delivering.withLock { $0 } }
                returned.set()
            }
            Self.waitUntil { returned.value || opened.suspendedStops >= 1 }
            delivering.withLock { $0 = false }
        }
        hardware.interrupt()
        #expect(await SuiteWait.until("the stop") { returned.value })
        await stopped.wait()
        #expect(deliveringAtReturn.withLock { $0 } == false, "The stop returned while the delivery ran.")
        #expect(engine.calls == ["installTap", "start", "stop", "removeTap"])
        #expect(hardware.uses.filter { $0 == "deactivate" }.count == 1)
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

    /// Runs the microphone's start on a thread of Dispatch's, not of the cooperative pool, and
    /// returns once it has returned.
    static func startOffThePool(
        _ opened: OpenMicrophone, format: AVAudioFormat, deliver: @escaping @Sendable (AudioDelivery) -> Void
    ) async throws {
        let started: Result<Void, KnotError> = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                do throws(KnotError) {
                    try opened.start(format: format, deliver: deliver)
                    continuation.resume(returning: .success(()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
        try started.get()
    }

    /// Blocks the calling thread until `condition` holds, for at most `SuiteWait.limit`. Only on a
    /// thread outside the cooperative pool.
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

    /// Starts `body`, once: on the cooperative pool, or with `offThePool` on a queue of its own,
    /// for a stop whose hooks block the thread it runs on while another task needs the pool.
    func start(offThePool: Bool = false, _ body: @escaping @Sendable () async -> Void) {
        task.withLock { task in
            guard task == nil else { return }
            if offThePool {
                task = Task(executorPreference: DispatchSerialQueue(label: "StopTask")) { await body() }
            } else {
                task = Task { await body() }
            }
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
/// makes a real engine. A test tells its session's events, as the system would.
final class StandInHardware: HardwareAudio {
    private let permission: Bool
    private let session: KnotError?
    private let engine: StandInEngine?
    private let used = Mutex<[String]>([])
    private let events = AsyncStream<SessionEvent>.makeStream()
    private let eventsEnded = Flag()

    var uses: [String] { used.withLock { $0 } }

    /// With no `engine`, making one fails, as it does when there is no input.
    init(permission: Bool = false, session: KnotError? = nil, engine: StandInEngine? = nil) {
        self.permission = permission
        self.session = session
        self.engine = engine
        events.continuation.onTermination = { [eventsEnded] _ in eventsEnded.set() }
    }

    /// True once whoever watched the session's events has stopped watching them.
    var sessionUnwatched: Bool { eventsEnded.value }

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

    func sessionEvents() -> AsyncStream<SessionEvent> { events.stream }

    /// The system takes the session, as a call does.
    func interrupt() { events.continuation.yield(.interrupted) }

    /// The media services are reset.
    func resetServices() { events.continuation.yield(.servicesReset) }

    /// The route changes, here as headphones that connect: `newDeviceAvailable`, 1.
    func changeRoute() { events.continuation.yield(.routeChanged(reason: 1)) }
}

/// An engine that opens nothing. It records each call, and runs a hook inside the tap's
/// installation or inside the start, so that a test delivers an ending at that point.
final class StandInEngine: InputEngine {
    enum Point: Sendable, Hashable {
        case installingTheTap
        case starting
        case stopping
    }

    private let shapes: Mutex<(tap: InputShape, hardware: InputShape)>
    private let startFailure = Mutex<KnotError?>(nil)
    private let state = Mutex<(calls: [String], tap: (@Sendable (AVReadOnlyAudioPCMBuffer) -> Void)?)>(([], nil))
    private let hooks = Mutex<[Point: @Sendable (StandInEngine) -> Void]>([:])
    private let changes = AsyncStream<Void>.makeStream()
    private let changesEnded = Flag()
    /// The last tap installed, kept after its removal.
    private let lastTap = Mutex<(@Sendable (AVReadOnlyAudioPCMBuffer) -> Void)?>(nil)

    init(tap: InputShape, hardware: InputShape? = nil) {
        shapes = Mutex((tap, hardware ?? tap))
        changes.continuation.onTermination = { [changesEnded] _ in changesEnded.set() }
    }

    /// True once whoever watched the configuration changes has stopped watching them.
    var configurationUnwatched: Bool { changesEnded.value }

    var tap: InputShape { shapes.withLock { $0.tap } }
    var hardware: InputShape { shapes.withLock { $0.hardware } }

    var calls: [String] { state.withLock { $0.calls } }

    /// The hardware changes to `shape`, for the tap and the hardware alike, as when headphones
    /// connect. The system then changes the engine's configuration.
    func setShape(_ shape: InputShape) { shapes.withLock { $0 = (shape, shape) } }

    /// The next start throws `error`.
    func failNextStart(with error: KnotError) { startFailure.withLock { $0 = error } }

    /// Runs `body` inside the call at `point`, before that call returns.
    func whenAt(_ point: Point, _ body: @escaping @Sendable (StandInEngine) -> Void) {
        hooks.withLock { $0[point] = body }
    }

    /// Tells the input that the engine's configuration changed, as the system would.
    func changeConfiguration() { changes.continuation.yield() }

    /// Hands the installed tap a buffer, as the input would.
    func deliver(_ buffer: AVReadOnlyAudioPCMBuffer) {
        let tap = state.withLock { $0.tap }
        tap?(buffer)
    }

    /// Hands the last tap installed a buffer, even once it is removed, as a callback still on its
    /// way on the engine's thread would.
    func deliverLate(_ buffer: AVReadOnlyAudioPCMBuffer) {
        let tap = lastTap.withLock { $0 }
        tap?(buffer)
    }

    func installTap(bufferSize: AVAudioFrameCount, _ tap: @escaping @Sendable (AVReadOnlyAudioPCMBuffer) -> Void)
        throws(KnotError)
    {
        state.withLock {
            $0.calls.append("installTap")
            $0.tap = tap
        }
        lastTap.withLock { $0 = tap }
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
        let failure = startFailure.withLock { failure in
            defer { failure = nil }
            return failure
        }
        if let failure { throw failure }
    }

    func stop() {
        state.withLock { $0.calls.append("stop") }
        run(at: .stopping)
    }

    func configurationChanges() -> AsyncStream<Void> { changes.stream }

    private func run(at point: Point) {
        let body = hooks.withLock { $0[point] }
        body?(self)
    }
}
