import Foundation
import KnotCore

/// The Watch's sequence of record, convert and send (docs/architecture.md §12, "Coordinator").
///
/// The Watch app only hosts it: the app's control calls `press(_:)`, and the app calls
/// `launch()` once at launch. A recording goes, in order, through these steps, each of which
/// survives a kill at any point:
///
/// 1. The recorder writes the recording's manifest and working file in `Recording/` before
///    the first sample, and returns once the recording is live.
/// 2. The stop returns once the working file is on the drive: the "Saved" cue may follow.
/// 3. The recorder converts the working file to AAC in `.m4a` and verifies it.
/// 4. The link admits the converted file to the outbox, then its manifest, with the
///    recording's end, length and checksum, and queues it.
/// 5. The recorder removes the working file and its manifest.
///
/// At every moment the recording's manifest is in `Recording/` or in `Outbox/`, and an
/// `Outbox/` manifest leaves only on the iPhone's acknowledgement. At the next launch the
/// recorder hands back each recording of an earlier launch whose working file is still there,
/// and the coordinator finishes it from the step it had reached: a conversion that a kill
/// interrupted is done again from the working file.
public actor WatchCoordinator {
    /// The points where a kill test stops the process (docs/architecture.md §17).
    public enum KillPoint: String, Hashable, Sendable, CaseIterable {
        /// The recording is live: its manifest and working file exist.
        case recordingLive = "recording_live"
        /// The stop returned: the working file is on the drive.
        case stopped
        /// The converted file is next to the working file.
        case converted
        /// The converted file is in the outbox and its manifest is not.
        case outboxRecording = "outbox_recording"
        /// The outbox holds the recording and its manifest, and it is queued.
        case sent
        /// The working file and its manifest are removed.
        case workingFileRemoved = "working_file_removed"
    }

    /// What a press did.
    public enum PressOutcome: Hashable, Sendable {
        /// A recording started and is live.
        case started(CaptureID)
        /// The recording stopped and is kept.
        case stopped(StopOutcome)
        /// A tap-started recording stopped within a second of its tap: discarded.
        case discarded(CaptureID)
        /// The recorder is starting or stopping, so the press is ignored.
        case ignored
        /// The recording could not start, for this reason.
        case failedToStart(KnotError)
    }

    /// Where a stopped recording ended up.
    public enum StopOutcome: Hashable, Sendable {
        /// In the outbox, queued for the iPhone.
        case sent(CaptureID)
        /// Kept as its working file, because a step failed. It is counted as waiting, or as
        /// failed after a final error, and tried again after the next stop and at the next launch.
        case kept(CaptureID, KnotError)
        /// Its manifest had no audio, so it was ended and nothing is kept.
        case endedWithoutAudio(CaptureID)
        /// An iPhone had already acknowledged it: what was left on the Watch was removed.
        case acknowledged(CaptureID)
    }

    /// A recording that ended other than by the caller's own press, stop or discard: at its
    /// limit, when a call took the audio, when the input went away, when a write failed or the
    /// disk filled. The Watch shows "stopped early" with its reason.
    public struct RecordingEndedByItself: Hashable, Sendable {
        public var captureID: CaptureID
        /// Why it ended: one of the endings for which `RecordingEnding.endedByItself` is true.
        public var ending: RecordingEnding
        /// What became of it: in the outbox, kept in `Recording/`, or ended.
        public var outcome: StopOutcome

        public init(captureID: CaptureID, ending: RecordingEnding, outcome: StopOutcome) {
            self.captureID = captureID
            self.ending = ending
            self.outcome = outcome
        }
    }

    private enum Activity {
        case idle
        case starting
        case recording(any RecordingSession, startedBy: Press)
        case stopping
    }

    private let recorder: any Recorder
    private let link: OutboxLink
    private let ids: any IDGenerator
    private let clock: any WallClock
    private let launchID: LaunchID
    private let device: DeviceID
    private let log: KnotLog
    private let killPoint: @Sendable (KillPoint) -> Void
    private var activity: Activity = .idle
    /// Recordings of this launch whose conversion or admission failed, tried again after the
    /// next stop and at the next launch.
    private var unfinished: [CaptureID: (recording: RecordedAudio, final: Bool)] = [:]
    /// The captures being finished now. The coordinator is reentrant while it awaits the
    /// recorder, so a second finish of the same capture would otherwise convert it twice at
    /// once.
    private var finishing: Set<CaptureID> = []
    /// The manifests the recorder wrote for the recordings this launch started, read once the
    /// recording is live. A recording keeps the start written when it began, even when a later
    /// read of its manifest fails.
    private var written: [CaptureID: CaptureManifest] = [:]
    /// Recordings that ended by themselves, in the order they ended, each with its outcome once
    /// its finish is done. A report leaves only from the front, so reports go out in order.
    private var endingsInOrder: [(capture: CaptureID, ending: RecordingEnding, outcome: StopOutcome?)] = []
    private let endingSubscribers = Subscribers<RecordingEndedByItself>()

    /// - Parameters:
    ///   - launchID: this launch. Recovery finishes only the recordings of other launches.
    ///   - device: the Watch's device ID, which each manifest records as its origin.
    ///   - killPoint: called at each point a kill test can stop at. The app passes nothing.
    public init(
        recorder: any Recorder, link: OutboxLink, ids: any IDGenerator, clock: any WallClock, launchID: LaunchID,
        device: DeviceID, log: KnotLog = KnotLog(.link), killPoint: @escaping @Sendable (KillPoint) -> Void = { _ in }
    ) {
        self.recorder = recorder
        self.link = link
        self.ids = ids
        self.clock = clock
        self.launchID = launchID
        self.device = device
        self.log = log
        self.killPoint = killPoint
    }

    // MARK: Launch

    /// Finishes the recordings that earlier launches left, clears what a kill left in the
    /// outbox, and starts the link's resume, without waiting for the session: recording
    /// never waits for the iPhone.
    ///
    /// What the Watch app may assume: call it once, at launch, and do not wait for it before
    /// taking presses. A press runs while it is converting an earlier launch's recording,
    /// because the coordinator takes other calls while it awaits the recorder, and a recording
    /// is never finished twice at once. The outbox's sweep runs on the link, which also admits,
    /// so the two never run side by side.
    public func launch() async {
        do {
            let recovered = try await recorder.recoverOrphans(currentLaunch: launchID)
            // Counted from the moment the link is up, before any conversion: each is on the
            // Watch and waits. Finishing it admits it, keeps it, or ends it, and recounts it.
            for recording in recovered {
                await link.hold(recording.captureID, failed: false)
            }
            for recording in recovered {
                _ = await finish(recording)
            }
        } catch {
            log.failure(error, "watch_recovery_failed")
        }
        await link.sweep()
        link.trigger()
    }

    // MARK: Recording

    /// A press of the record control, the complication, Double Tap or an intent. Decided by
    /// the press rule of docs/product-spec.md §4.2: it starts a recording when idle, stops and
    /// keeps it when recording, discards a tap-started one stopped within a second, and is
    /// ignored while the recorder starts or stops.
    public func press(_ press: Press, placement: CapturePlacement = .window) async -> PressOutcome {
        let state: RecorderActivity =
            switch activity {
            case .idle: .idle
            case .starting: .starting
            case .recording(_, let start): .recording(startedBy: start)
            case .stopping: .stopping
            }
        // The coordinator's recorder is the truth in this process, and launch has finished
        // the orphans, so no saved state is passed.
        switch RecordingPressRule.decide(press, recorder: state, saved: nil) {
        case .start, .recoverOrphanThenStart:
            do {
                return .started(try await start(press, placement: placement))
            } catch {
                return .failedToStart(error)
            }
        case .stopAndKeep:
            guard let outcome = await stop() else { return .ignored }
            return .stopped(outcome)
        case .stopAndDiscard:
            guard let capture = await discard() else { return .ignored }
            return .discarded(capture)
        case .ignore:
            return .ignored
        }
    }

    /// Starts a recording and returns once it is live.
    public func start(_ press: Press = Press(.tap, at: Date()), placement: CapturePlacement = .window)
        async throws(KnotError) -> CaptureID
    {
        guard case .idle = activity else { throw KnotError.captureBlockedByRecording }
        activity = .starting
        let capture: CaptureID = ids.make()
        let request = RecordingRequest(
            captureID: capture, launchID: launchID, origin: CaptureOrigin(source: .device(device), surface: .watch),
            placement: placement)
        do {
            let session = try await recorder.start(request)
            activity = .recording(session, startedBy: press)
            written[capture] = readWrittenManifest(capture)
            log.capture(capture, "watch_recording_live")
            watchForItsEnd(session)
            killPoint(.recordingLive)
            return capture
        } catch {
            activity = .idle
            log.failure(error.about(capture: capture), "watch_recording_failed_to_start")
            throw error
        }
    }

    /// Stops the recording, converts it and sends it. With no recording, nothing happens and
    /// `nil` is returned.
    @discardableResult
    public func stop() async -> StopOutcome? {
        guard case .recording(let session, _) = activity else { return nil }
        activity = .stopping
        let recorded = await session.stop()
        activity = .idle
        log.capture(recorded.captureID, "watch_recording_saved", .duration("length", recorded.duration))
        killPoint(.stopped)
        let outcome = await finish(recorded)
        await finishUnfinished(except: recorded.captureID)
        // A recording that has just stopped is finished by nobody else, so there is always an
        // outcome; were there none, the recording stays in Recording/ for the next launch.
        return outcome ?? .kept(recorded.captureID, KnotError.illegalTransition.about(capture: recorded.captureID))
    }

    /// The coordinator is the one consumer of a session's events. A recording that ends by
    /// itself, at its limit, when a call takes the audio or when the disk fills, is finished
    /// like a stopped one, and the coordinator is idle again, so the next press starts.
    private func watchForItsEnd(_ session: any RecordingSession) {
        let events = session.events
        Task { [weak self] in
            for await event in events {
                guard case .ended(let recorded) = event else { continue }
                await self?.ended(recorded)
                return
            }
        }
    }

    /// A session's end. A stop or a discard has already taken the recording out of
    /// `.recording`, so only an end that came by itself is finished here.
    private func ended(_ recorded: RecordedAudio) async {
        guard case .recording(let session, _) = activity, session.captureID == recorded.captureID else { return }
        activity = .idle
        log.capture(
            recorded.captureID, "watch_recording_ended_by_itself", .duration("length", recorded.duration),
            .flag("disk_full", recorded.ending == .diskFull), .flag("limit", recorded.ending == .limitReached))
        killPoint(.stopped)
        let capture = recorded.captureID
        endingsInOrder.append((capture, recorded.ending, nil))
        let outcome =
            await finish(recorded) ?? .kept(capture, KnotError.illegalTransition.about(capture: capture))
        if let index = endingsInOrder.firstIndex(where: { $0.capture == capture && $0.outcome == nil }) {
            endingsInOrder[index].outcome = outcome
        }
        reportEndings()
        await finishUnfinished(except: capture)
    }

    /// Reports, from the front, every recording that ended by itself and has reached where it
    /// will stay. One whose finish is still under way holds back those that ended after it.
    private func reportEndings() {
        while let first = endingsInOrder.first, let outcome = first.outcome {
            endingsInOrder.removeFirst()
            log.capture(first.capture, "watch_recording_ended_by_itself_reported")
            endingSubscribers.yield(
                RecordingEndedByItself(captureID: first.capture, ending: first.ending, outcome: outcome))
        }
    }

    /// The recordings that end other than by the caller's own press, stop or discard, each
    /// reported once, in the order they ended, and only after the recording is where it will
    /// stay: in the outbox, kept in `Recording/`, or ended. A listener is told only what ends
    /// after it subscribes, and nothing that ended before: what is still on the Watch is in the
    /// link's counts. Recordings that earlier launches left are not reported here, since
    /// `launch()` finishes them and the counts show them. A listener that goes away changes
    /// nothing for the recording.
    public nonisolated func endings() -> AsyncStream<RecordingEndedByItself> {
        endingSubscribers.stream()
    }

    /// Discards the recording, as an accidental press. Returns its capture, or `nil` when
    /// nothing was recording.
    @discardableResult
    public func discard() async -> CaptureID? {
        guard case .recording(let session, _) = activity else { return nil }
        activity = .stopping
        await session.discard()
        written[session.captureID] = nil
        activity = .idle
        log.capture(session.captureID, "watch_recording_discarded")
        return session.captureID
    }

    /// The recordings of this launch that stopped but are not in the outbox yet, because their
    /// conversion or admission failed. They stay in `Recording/` and are tried again after
    /// the next stop and at the next launch.
    public var keptRecordings: [CaptureID] { unfinished.keys.sorted() }

    /// True while a recording is live.
    public var isRecording: Bool {
        if case .recording = activity { return true }
        return false
    }

    // MARK: Convert and send

    /// Takes a stopped or recovered recording through conversion, the outbox and the removal
    /// of its working file, from wherever it stands. Every way out that keeps the recording
    /// writes a line with its capture ID.
    ///
    /// Returns `nil`, and does nothing, when the capture is being finished already.
    private func finish(_ recording: RecordedAudio) async -> StopOutcome? {
        let capture = recording.captureID
        guard finishing.insert(capture).inserted else { return nil }
        defer { finishing.remove(capture) }
        if await link.hasBeenAcknowledged(capture) {
            // An iPhone has it: what is left here goes, and nothing is converted or sent again.
            return await removeAcknowledgedLeftovers(capture)
        }
        if let entry = link.outbox.entry(capture), entry.hasRecording, entry.manifest != nil {
            // Already in the outbox, but perhaps by an admission whose folder sync failed: the
            // working pair goes only once the entry is known to be durable.
            do {
                try await link.makeDurable(capture)
            } catch {
                log.failure(error, "watch_outbox_entry_not_durable")
                return await keep(recording, error)
            }
            unfinished[capture] = nil
            await link.release(capture)
            return await removeWorkingFile(capture)
        }
        guard link.outbox.holdsRecording(capture) || recording.workingFile != nil else {
            // A manifest with no audio, which a start that failed can leave: nothing to keep.
            return await endWithoutAudio(capture)
        }
        guard let started = writtenManifest(capture) else {
            // Nothing to date it by: it is kept, with its manifest, for a later try, and no
            // time is made up.
            log.capture(capture, "watch_recording_manifest_unreadable", level: .error)
            return await keep(recording, KnotError.inboxItemUnreadable.about(capture: capture))
        }
        if link.outbox.holdsRecording(capture) {
            // The converted file reached the outbox and its manifest did not: admit that file,
            // which a move placed whole, rather than convert again.
            log.capture(capture, "watch_recording_found_in_outbox")
            return await admit(
                recording, written: started, file: link.outbox.recordingURL(capture), duration: recording.duration)
        }
        let converted: ConvertedRecording
        do {
            converted = try await recorder.convert(recording)
        } catch {
            let error = error.about(capture: capture)
            log.failure(error, "watch_conversion_failed")
            return await keep(recording, error)
        }
        killPoint(.converted)
        return await admit(recording, written: started, file: converted.file, duration: converted.duration)
    }

    /// Admits a converted recording to the outbox and removes its working file.
    private func admit(_ recording: RecordedAudio, written started: CaptureManifest, file: URL, duration: Duration)
        async -> StopOutcome
    {
        let capture = recording.captureID
        var manifest = started
        manifest.duration = duration
        manifest.endedAt = started.startedAt.addingTimeInterval(Self.seconds(duration))
        do {
            try await link.send(manifest, file: file, afterRecording: { killPoint(.outboxRecording) })
        } catch {
            let error = error.about(capture: capture)
            log.failure(error, "watch_admission_failed")
            return await keep(recording, error)
        }
        killPoint(.sent)
        unfinished[capture] = nil
        written[capture] = nil
        return await removeWorkingFile(capture)
    }

    /// Keeps a recording in `Recording/` after a step failed. The link counts it as waiting
    /// while a retry can succeed, and as failed after a final error, which is not tried again
    /// in this launch. The next launch tries every kept recording again.
    private func keep(_ recording: RecordedAudio, _ error: KnotError) async -> StopOutcome {
        let capture = recording.captureID
        unfinished[capture] = (recording, error.isFinal)
        await link.hold(capture, failed: error.isFinal)
        log.capture(capture, "watch_recording_kept", .code(error.code), .flag("final", error.isFinal))
        return .kept(capture, error)
    }

    /// Ends a recording whose manifest has no audio: its manifest goes, and it is counted
    /// nowhere, so nothing stays in `Recording/` for ever.
    private func endWithoutAudio(_ capture: CaptureID) async -> StopOutcome {
        unfinished[capture] = nil
        written[capture] = nil
        await link.release(capture)
        do {
            try await recorder.removeWorkingFile(of: capture)
            log.capture(capture, "watch_recording_without_audio_ended")
        } catch {
            log.failure(error.about(capture: capture), "watch_recording_without_audio_not_removed")
        }
        return .endedWithoutAudio(capture)
    }

    /// Removes what is left in `Recording/` of a capture that an iPhone acknowledged. The marker
    /// that says so stays: the outbox's sweep removes it once nothing else of the capture is left,
    /// which at launch follows recovery.
    private func removeAcknowledgedLeftovers(_ capture: CaptureID) async -> StopOutcome {
        unfinished[capture] = nil
        written[capture] = nil
        await link.release(capture)
        do {
            try await recorder.removeWorkingFile(of: capture)
            log.capture(capture, "watch_acknowledged_leftovers_removed")
        } catch {
            log.failure(error.about(capture: capture), "watch_acknowledged_leftovers_not_removed")
        }
        return .acknowledged(capture)
    }

    private func removeWorkingFile(_ capture: CaptureID) async -> StopOutcome {
        do {
            try await recorder.removeWorkingFile(of: capture)
            killPoint(.workingFileRemoved)
        } catch {
            // The recording is safe in the outbox; the working file is removed at the next launch.
            log.failure(error.about(capture: capture), "watch_working_file_not_removed")
        }
        return .sent(capture)
    }

    /// Tries again the recordings this launch kept, apart from those a final error kept. The
    /// coordinator takes other calls while a retry awaits the recorder, so each capture is
    /// looked at again just before it is tried: one that another finish has sent, or that an
    /// iPhone has acknowledged meanwhile, is no longer kept and is left alone.
    private func finishUnfinished(except capture: CaptureID) async {
        for other in unfinished.keys.sorted() where other != capture {
            guard let kept = unfinished[other], !kept.final else { continue }
            _ = await finish(kept.recording)
        }
    }

    /// The manifest the recorder wrote before the first sample: the one held since the
    /// recording went live, or else the one in `Recording/`. `nil` when neither is there to read.
    private func writtenManifest(_ capture: CaptureID) -> CaptureManifest? {
        written[capture] ?? readWrittenManifest(capture)
    }

    private func readWrittenManifest(_ capture: CaptureID) -> CaptureManifest? {
        let url = link.outbox.locations.recordingManifest(capture)
        guard let data = try? Data(contentsOf: url), let read = try? CaptureManifest.decode(data),
            read.captureID == capture
        else { return nil }
        return read
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
