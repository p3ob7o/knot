import AVFAudio
import Foundation
import KnotCore
import KnotTestSupport
import Synchronization
import Testing

@testable import KnotAudio

/// What the session and the hardware do to a recording: an interruption, a reset of the media
/// services, a route change and the engine's change of configuration, on the stand-in engine and
/// session, which open nothing. What a device really does is checked at the owner's sitting.
@Suite struct InterruptionTests {
    /// An interruption, a call taking the session, ends the recording as `interrupted`, and
    /// everything written before it is kept, in the working file.
    @Test func anInterruptionEndsTheRecordingWithEverythingKept() async throws {
        let folder = try ScratchFolder()
        let (input, engine, hardware) = Self.standInMicrophone(InputShape(sampleRate: 48_000, channels: 1))
        let live = recorder(folder.locations, input: input)
        let session = try await live.start(request())
        var tone = try #require(Tone(rate: 48_000, channels: 1))
        for _ in 0..<3 { engine.deliver(try tone.next(4_800)) }
        await durable(atLeast: 14_400, of: session)
        hardware.interrupt()
        guard case .ended(let audio)? = await allEvents(of: session, limit: .seconds(10)).last else {
            Issue.record("The recording did not end by itself.")
            return
        }
        #expect(audio.ending == .interrupted, "\(audio)")
        let working = try #require(audio.workingFile)
        #expect(audio.frames == 14_400 && WorkingFileReader.contents(of: working)?.frames == 14_400)
        #expect(engine.calls == ["installTap", "start", "stop", "removeTap"], "\(engine.calls)")
        #expect(hardware.uses.filter { $0 == "deactivate" }.count == 1)
    }

    /// Headphones that connect at another rate: the engine changes its configuration, the input
    /// puts its tap back in the new format and starts again, and what it delivers from then on is
    /// converted into the working file's rate. The file keeps its rate for its whole length, and
    /// the tone after the change is still a 1 kHz tone at the file's rate.
    @Test func aNewRateIsCarriedIntoTheFilesRate() async throws {
        let folder = try ScratchFolder()
        let (input, engine, _) = Self.standInMicrophone(InputShape(sampleRate: 48_000, channels: 1))
        let live = recorder(folder.locations, input: input)
        let session = try await live.start(request())
        var before = try #require(Tone(rate: 48_000, channels: 1))
        engine.deliver(try before.next(4_800))
        engine.setShape(InputShape(sampleRate: 44_100, channels: 2))
        engine.changeConfiguration()
        let restarted = ["installTap", "start", "stop", "removeTap", "installTap", "start"]
        #expect(
            await SuiteWait.until("the restart", limit: .seconds(10)) { engine.calls == restarted }, "\(engine.calls)")
        var after = try #require(Tone(rate: 44_100, channels: 2))
        for _ in 0..<10 { engine.deliver(try after.next(4_410)) }
        let audio = await session.stop()
        #expect(audio.ending == .stopped, "\(audio)")
        let working = try #require(audio.workingFile)
        let contents = try #require(WorkingFileReader.contents(of: working))
        #expect(contents.sampleRate == 48_000)
        // A second at 44.1 kHz is 48,000 frames at 48 kHz, less what the converter still holds.
        let converted = contents.frames - 4_800
        #expect(Int64(48_000 - Carrying.heldBack(at: 48_000))...48_000 ~= converted, "\(converted) after the change")
        let samples = try #require(WorkingFileReader.samples(of: working))
        try #require(samples.count > 5_200, "\(samples.count) frames in the file")
        let frequency = Tone.frequency(of: Array(samples[5_000..<(samples.count - 200)]), rate: 48_000)
        #expect(abs(frequency - 1_000) < 5, "The tone after the change is \(frequency) Hz.")
    }

    /// An engine that cannot start again after its change ends the recording as `input_lost`,
    /// with everything written before it kept. The tap it put back is taken away.
    @Test func anEngineThatCannotStartAgainLosesTheInput() async throws {
        let folder = try ScratchFolder()
        let (input, engine, hardware) = Self.standInMicrophone(InputShape(sampleRate: 48_000, channels: 1))
        let live = recorder(folder.locations, input: input)
        let session = try await live.start(request())
        var tone = try #require(Tone(rate: 48_000, channels: 1))
        engine.deliver(try tone.next(4_800))
        await durable(atLeast: 4_800, of: session)
        engine.failNextStart(with: .audioSessionBusy)
        engine.changeConfiguration()
        guard case .ended(let audio)? = await allEvents(of: session, limit: .seconds(10)).last else {
            Issue.record("The recording did not end by itself.")
            return
        }
        #expect(audio.ending == .inputLost, "\(audio)")
        let working = try #require(audio.workingFile)
        #expect(audio.frames == 4_800 && WorkingFileReader.contents(of: working)?.frames == 4_800)
        #expect(
            engine.calls == ["installTap", "start", "stop", "removeTap", "installTap", "start", "removeTap"],
            "\(engine.calls)")
        #expect(hardware.uses.filter { $0 == "deactivate" }.count == 1)
    }

    /// A configuration change at the same rate starts the engine again on a fresh tap, and the
    /// recording goes on: no ending is delivered, and both buffers are. Once the input is
    /// stopped, nothing watches the engine or the session any more.
    @Test func aChangeAtTheSameRateGoesOn() async throws {
        let (opened, engine, hardware) = try await HardwareInputTests.openStandIn()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(HardwareInputTests.silence(format))
        let deliveries = Mutex<[String]>([])
        try opened.start(format: format) { delivery in deliveries.withLock { $0.append(Self.describe(delivery)) } }
        engine.deliver(buffer)
        engine.changeConfiguration()
        #expect(await SuiteWait.until("the restart", limit: .seconds(10)) { opened.restarts == 1 })
        engine.deliver(buffer)
        await opened.stop()
        #expect(deliveries.withLock { $0 } == ["audio 1600", "audio 1600"])
        #expect(
            engine.calls == ["installTap", "start", "stop", "removeTap", "installTap", "start", "stop", "removeTap"],
            "\(engine.calls)")
        #expect(hardware.uses.filter { $0 == "deactivate" }.count == 1)
        #expect(
            await SuiteWait.until("the watchers to end") { engine.configurationUnwatched && hardware.sessionUnwatched })
    }

    /// A reset of the media services ends the recording as `input_lost`. After the stop, the
    /// session's events deliver nothing.
    @Test func aResetOfTheMediaServicesLosesTheInput() async throws {
        let (opened, engine, hardware) = try await HardwareInputTests.openStandIn()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let deliveries = Mutex<[String]>([])
        try opened.start(format: format) { delivery in deliveries.withLock { $0.append(Self.describe(delivery)) } }
        hardware.resetServices()
        #expect(await SuiteWait.until("the ending") { !deliveries.withLock { $0 }.isEmpty })
        await opened.stop()
        hardware.interrupt()
        #expect(deliveries.withLock { $0 } == ["ended lost"])
        #expect(engine.calls == ["installTap", "start", "stop", "removeTap"], "\(engine.calls)")
    }

    /// A route change alone changes nothing: the engine's own change follows one that changes the
    /// hardware. The events are handled in their order, so the interruption after it is the one
    /// ending.
    @Test func aRouteChangeAloneChangesNothing() async throws {
        let (opened, engine, hardware) = try await HardwareInputTests.openStandIn()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let deliveries = Mutex<[String]>([])
        try opened.start(format: format) { delivery in deliveries.withLock { $0.append(Self.describe(delivery)) } }
        hardware.changeRoute()
        hardware.interrupt()
        #expect(await SuiteWait.until("the ending", limit: .seconds(10)) { !deliveries.withLock { $0 }.isEmpty })
        await opened.stop()
        #expect(deliveries.withLock { $0 } == ["ended interrupted"])
        #expect(engine.calls == ["installTap", "start", "stop", "removeTap"], "\(engine.calls)")
    }

    /// A stop asked for while the restart puts its tap back waits for the restart, which then
    /// starts nothing and takes the tap away: when the stop returns, nothing runs. The hook holds
    /// the input's own queue, never a thread of the cooperative pool.
    @Test func aStopDuringTheRestartWaitsForIt() async throws {
        let (opened, engine, hardware) = try await HardwareInputTests.openStandIn()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let stopping = StopTask()
        let seen = Mutex<[String]?>(nil)
        engine.whenAt(.installingTheTap) { engine in
            guard engine.calls.filter({ $0 == "installTap" }).count == 2 else { return }
            stopping.start {
                await opened.stop()
                seen.withLock { $0 = engine.calls }
            }
            HardwareInputTests.waitUntil { opened.suspendedStops >= 1 || seen.withLock { $0 } != nil }
        }
        try opened.start(format: format) { _ in }
        engine.changeConfiguration()
        #expect(await SuiteWait.until("the stop", limit: .seconds(10)) { opened.stopRequested })
        await stopping.wait()
        #expect(
            seen.withLock { $0 } == ["installTap", "start", "stop", "removeTap", "installTap", "removeTap"],
            "\(String(describing: seen.withLock { $0 }))")
        #expect(opened.restarts == 0)
        #expect(hardware.uses.filter { $0 == "deactivate" }.count == 1)
    }

    /// The carrier converts a tap's rate into the file's at every pair of rates the hardware
    /// gives: a second of a 1 kHz tone comes out as a second at the file's rate, less what the
    /// converter holds, and still at 1 kHz.
    @Test(arguments: [
        (44_100.0, 48_000.0), (48_000.0, 44_100.0), (48_000.0, 16_000.0), (16_000.0, 48_000.0),
        (24_000.0, 48_000.0), (96_000.0, 48_000.0),
    ])
    func theCarrierConvertsIntoTheFilesRate(tapRate: Double, fileRate: Double) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: fileRate, channels: 1))
        let carrier = try #require(Carrier(tapRate: tapRate, into: format))
        var tone = try #require(Tone(rate: tapRate, channels: 2))
        var samples: [Float] = []
        for _ in 0..<10 {
            let carried = try #require(carrier.carry(try tone.next(Int(tapRate / 10))))
            #expect(carried.format == format)
            samples += Tone.samples(of: carried)
        }
        let expected = Int(fileRate)
        #expect((expected - Carrying.heldBack(at: fileRate))...expected ~= samples.count, "\(samples.count) frames")
        let frequency = Tone.frequency(of: samples.dropFirst(200).map { Int16($0 * 32_767) }, rate: fileRate)
        #expect(abs(frequency - 1_000) < 5, "\(frequency) Hz")
    }

    /// The stand-in microphone: an input on a stand-in engine of `shape` and a stand-in session,
    /// which open nothing.
    static func standInMicrophone(_ shape: InputShape) -> (MicrophoneInput, StandInEngine, StandInHardware) {
        let engine = StandInEngine(tap: shape)
        let hardware = StandInHardware(permission: true, engine: engine)
        return (MicrophoneInput(hardware: hardware, policy: { nil }), engine, hardware)
    }

    static func describe(_ delivery: AudioDelivery) -> String {
        switch delivery {
        case .audio(let buffer): "audio \(buffer.frameLength)"
        case .ended(let why): "ended \(why.rawValue)"
        }
    }
}

/// What a converter of the input still holds when the recording stops, at most: 20 ms of the
/// file's rate. Measured, it is 8 to 262 frames for the pairs of rates here, the most at 48 kHz
/// into 16 kHz, 16 ms.
enum Carrying {
    static func heldBack(at rate: Double) -> Int { Int(rate / 50) }
}

/// A 1 kHz tone at half scale, the same on every channel, from frame 0 on.
struct Tone {
    let format: AVAudioFormat
    private var frame = 0

    init?(rate: Double, channels: AVAudioChannelCount) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels) else { return nil }
        self.format = format
    }

    /// The next `frames` frames of the tone.
    mutating func next(_ frames: Int) throws -> AVReadOnlyAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        let channels = try #require(buffer.floatChannelData)
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames {
            let value = Float(0.5 * sin(2 * Double.pi * 1_000 * Double(frame + index) / format.sampleRate))
            for channel in 0..<Int(format.channelCount) { channels[channel][index] = value }
        }
        frame += frames
        return AVReadOnlyAudioPCMBuffer(copying: buffer)
    }

    /// The samples of a buffer of one channel.
    static func samples(of buffer: AVReadOnlyAudioPCMBuffer) -> [Float] {
        buffer.withUnsafeAudioBufferList { list in
            guard let data = list.pointee.mBuffers.mData else { return [] }
            let samples = data.assumingMemoryBound(to: Float.self)
            return (0..<Int(buffer.frameLength)).map { samples[$0] }
        }
    }

    /// The frequency of a tone, by its rising crossings of zero.
    static func frequency(of samples: [Int16], rate: Double) -> Double {
        var rising = 0
        for index in samples.indices.dropFirst() where samples[index - 1] < 0 && samples[index] >= 0 { rising += 1 }
        return Double(rising) * rate / Double(samples.count)
    }
}
