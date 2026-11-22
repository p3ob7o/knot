import AVFAudio
import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

@testable import KnotAudio

/// The live player, rendering offline: nothing plays aloud on the build Mac, and a test moves
/// the audio on itself.
@Suite struct PlayerTests {
    /// The live player passes the `AudioPlayer` contract on a working file of two seconds, and
    /// refuses a file that is not audio with `audio_unreadable`.
    @Test(.tags(.contract)) func theLivePlayerPassesItsContract() async throws {
        let folder = try ScratchFolder()
        let file = folder.file("two-seconds.caf")
        _ = try writeWorkingFile(at: file, frames: 32_000)
        let unreadable = folder.file("not-audio.caf")
        try Data("not audio".utf8).write(to: unreadable)
        try await AudioPlayerContract.run(file: file, length: .seconds(2), unreadable: unreadable) {
            LiveAudioPlayer(output: .offline)
        }
    }

    /// The live entry point gives the player, and the recording state in the defaults it is
    /// given, none without them; and the recorder it wires gives its cues through the
    /// environment's emitter and publishes its recording in that state.
    @Test func theEntryPointWiresThePlayerTheStateAndTheCues() async throws {
        let suite = try TestSuite()
        defer { suite.remove() }
        var environment = AppEnvironment.unavailable
        let cues = RecordingCueEmitter()
        environment.cues = cues
        let plain = KnotAudioLive.wire(environment)
        #expect(plain.player is LiveAudioPlayer)
        #expect(plain.recordingState is UnavailableRecordingStateStore, "With no defaults given, no state store.")
        let folder = try ScratchFolder()
        let wired = KnotAudioLive.wire(
            environment, locations: folder.locations, input: injected(), recordingState: suite.defaults)
        #expect(wired.recordingState is DefaultsRecordingStateStore)
        let started = request()
        let session = try await wired.recorder.start(started)
        #expect(wired.recordingState.read().phase == .recording)
        #expect(await cuesHandedOver(by: wired.recorder, to: cues, refusing: started) == [.recordingLive])
        #expect(wired.recordingState.read().phase == .recording, "A refused start leaves the state alone.")
        _ = await session.stop()
        #expect(wired.recordingState.read() == .idle)
    }

    /// The one policy decides where the player's audio goes (finding 4 of the review): in a
    /// process whose hardware input `HardwareInputPolicy` refuses, a test's as this one, a
    /// simulator's or an agent's, the player renders offline and plays nothing aloud; elsewhere it
    /// plays on the device.
    @Test func thePolicyChoosesThePlayersOutput() {
        #expect(HardwareInputPolicy.refusalForThisProcess() != nil, "A test process is refused.")
        #expect(LiveAudioPlayer().output == .offline, "The live entry point's player in a test.")
        for refusal in [HardwareInputPolicy.Refusal.simulator, .test, .agent] {
            #expect(LiveAudioPlayer(refusal: refusal).output == .offline, "\(refusal)")
        }
        #expect(LiveAudioPlayer(refusal: nil).output == .device)
    }

    /// A play while this process records is refused, and the recording wins (the orchestrator's
    /// ruling on this pull request): nothing renders, the player's state does not change, and the
    /// recording runs on to its own end with every frame. One log line says so, with the asset
    /// the file's name gives and nothing made from its content.
    @Test func aPlayWhileRecordingIsRefused() async throws {
        let folder = try ScratchFolder()
        let activity = AudioActivity()
        let (input, engine, _) = InterruptionTests.standInMicrophone(
            InputShape(sampleRate: 48_000, channels: 1), activity: activity)
        let live = recorder(folder.locations, input: input)
        let session = try await live.start(request())
        var tone = try #require(Tone(rate: 48_000, channels: 1))
        engine.deliver(try tone.next(4_800))
        let asset = AssetID(uuid: UUID())
        let file = folder.file("\(asset).caf")
        _ = try writeWorkingFile(at: file, frames: 32_000)
        let kept = KeptLog()
        let player = LiveAudioPlayer(output: .offline, log: KnotLog(.audio, sink: kept), activity: activity)
        _ = try await player.load(file)
        await player.play()
        #expect(player.currentState == .paused(at: .zero, of: .seconds(2)), "\(player.currentState)")
        #expect(await player.renderOffline(4_800) == 0, "Nothing renders.")
        engine.deliver(try tone.next(4_800))
        let audio = await session.stop()
        #expect(audio.ending == .stopped && audio.frames == 9_600, "\(audio)")
        let lines = kept.lines("player_refused_while_recording")
        #expect(lines.count == 1 && lines.first?.fields == [.asset(asset)], "\(lines)")
        // Once the recording has stopped, the player plays again.
        await player.play()
        #expect(player.currentState == .playing(at: .zero, of: .seconds(2)), "\(player.currentState)")
        await player.pause()
    }

    /// A recording that starts stops a player that plays, which says that it paused where it
    /// stood, never playing for ever: half a second rendered, it is paused half a second in once
    /// the start has returned.
    @Test func aRecordingThatStartsPausesThePlayer() async throws {
        let folder = try ScratchFolder()
        let activity = AudioActivity()
        let file = folder.file("two-seconds.caf")
        _ = try writeWorkingFile(at: file, frames: 32_000)
        let player = LiveAudioPlayer(output: .offline, activity: activity)
        _ = try await player.load(file)
        await player.play()
        _ = await player.renderOffline(8_000)
        let (input, _, _) = InterruptionTests.standInMicrophone(
            InputShape(sampleRate: 48_000, channels: 1), activity: activity)
        let session = try await recorder(folder.locations, input: input).start(request())
        guard case .paused(let at, let length) = player.currentState else {
            Issue.record("The player plays on under a recording: \(player.currentState)")
            _ = await session.stop()
            return
        }
        #expect(length == .seconds(2) && at >= .milliseconds(400) && at <= .milliseconds(500), "\(at)")
        _ = await session.stop()
    }

    /// What it renders moves it on: a second rendered is a second played, told as it plays, and
    /// at the end of the recording it has ended. A play from the end plays again from the start.
    /// The converted copy, the stored format, plays the same.
    @Test(arguments: [false, true])
    func aRecordingPlaysToItsEnd(converted: Bool) async throws {
        let folder = try ScratchFolder()
        // Two seconds recorded and, for the stored format, converted, as the app does.
        let live = recorder(folder.locations, input: injected(frames: 32_000))
        let session = try await live.start(request())
        await durable(atLeast: 32_000, of: session)
        let audio = await session.stop()
        var file = try #require(audio.workingFile)
        if converted { file = try await live.convert(audio).file }
        let player = LiveAudioPlayer(output: .offline)
        #expect(try await player.load(file) == .seconds(2))
        await player.play()
        #expect(await player.renderOffline(16_000) == 16_000)
        #expect(
            await SuiteWait.until("the position a second in") {
                guard case .playing(let at, _) = player.currentState else { return false }
                return at >= .milliseconds(900)
            }, "\(player.currentState)")
        guard case .playing(let at, _) = player.currentState else {
            Issue.record("It plays on: \(player.currentState)")
            return
        }
        #expect(at <= .seconds(1), "A second rendered is no more than a second played: \(at)")
        _ = await player.renderOffline(20_000)
        #expect(
            await SuiteWait.until("the end") { player.currentState == .ended(.seconds(2)) }, "\(player.currentState)")
        await player.play()
        #expect(
            player.currentState == .playing(at: .zero, of: .seconds(2)),
            "From the end it plays again from the start: \(player.currentState)")
        // Half a second rendered from the start is half a second in, never the end.
        _ = await player.renderOffline(8_000)
        #expect(
            await SuiteWait.until("the position half a second in") {
                guard case .playing(let at, _) = player.currentState else { return false }
                return at >= .milliseconds(400)
            }, "\(player.currentState)")
        guard case .playing(let again, _) = player.currentState, again <= .milliseconds(500) else {
            Issue.record("Half a second rendered plays half a second: \(player.currentState)")
            return
        }
        // A seek while it plays plays on from there: 600 ms from 1.5 s reach the end.
        await player.seek(to: .milliseconds(1_500))
        _ = await player.renderOffline(9_600)
        #expect(await SuiteWait.until("the end after the seek") { player.currentState == .ended(.seconds(2)) })
    }
}
