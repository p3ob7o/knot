#if DEBUG || KNOT_FAKES
    import CryptoKit
    import Foundation
    import KnotCapture
    import KnotCore
    import KnotFakes
    import KnotStore
    import Synchronization

    /// One launch of the soak's child over the real store (docs/architecture.md §17): it
    /// composes the store, the capture engine, ingest and recovery as the app does, over the
    /// live recorder on injected audio, the scripted transcriber and cleaner and an injected
    /// clock; it recovers what the launches before it left; then it runs its part of the script,
    /// and tells its parent each save the engine acknowledged, and each recording's durable
    /// frames.
    ///
    /// Its lines:
    ///
    ///     launch <n>                      the store is open
    ///     recovered <count>               recovery has run: the captures it finished
    ///     intent <index>                  capture <index> of the script is about to begin
    ///     ack <index> <capture> <revision> <bytes> <sha256> <open|ended|discarded> <blank>
    ///                                     the engine answered a save of that capture as durable at
    ///                                     that revision, with a text of that many UTF-8 bytes and
    ///                                     that digest; <blank> is 1 when the text is only spaces
    ///                                     and line breaks
    ///     discarding <index> <capture>    the script discards that capture now
    ///     refused <index> <code>          an engine call threw: nothing of it was acknowledged
    ///     stopped <point>                 the child waits at its kill point to be killed
    ///     log <category> <line>           an error a part logged: IDs and codes only
    ///     done                            the launch ran its part to the end, and exits
    /// The engine's deadline in the soak: it runs out at once while the script holds a write,
    /// and otherwise gives the store two minutes. So whether a write takes `Inbox/` is the
    /// script's choice, which the seed fixes, and never how fast a loaded machine answers.
    final class ScriptedDeadline: Sendable {
        private let expired = Mutex(false)

        func expires(_ now: Bool) { expired.withLock { $0 = now } }

        var deadline: StoreDeadline {
            StoreDeadline { [self] in
                guard !expired.withLock({ $0 }) else { return }
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    /// A launch's recovery and its report of what recovery left, apart from the launch so that
    /// it can run beside the launch's captures.
    struct RecoveryRun: Sendable {
        let recovery: LaunchRecovery
        let ingest: InboxIngest
        let notes: NoteRepository
        let locations: StoreLocations
        let launchID: LaunchID
        /// The injected fault `skippedRecovery`.
        let skipped: Bool
        /// Whether the launch's captures run beside it, so that `Inbox/` may hold their items.
        let capturing: Bool

        func run() async {
            if skipped {
                Say.line(SoakLine.recovered(0).rendered)
            } else {
                do {
                    let outcomes = try await recovery.run(ingest: ingest)
                    Say.line(SoakLine.recovered(outcomes.count).rendered)
                    // Recovery finishes only captures of earlier launches: one of this launch, which
                    // a launch that captures meanwhile may have open, is not its to end.
                    var own = 0
                    for id in outcomes.keys {
                        if let row = try await notes.capture(id), row.launchID == launchID { own += 1 }
                    }
                    Say.line(SoakLine.recoveredOwn(own).rendered)
                } catch {
                    Say.fail("recovery failed: \(error.code)")
                }
            }
            await reportWhatRecoveryLeft()
        }

        /// Says what recovery left of earlier launches: their rows still open, and every entry in
        /// `Inbox/`, whatever its name. A launch that captures meanwhile counts only what is provably
        /// an earlier launch's (`InboxEntries.list(_:besides:)`); another has written nothing there
        /// yet, so everything in it is an earlier launch's.
        private func reportWhatRecoveryLeft() async {
            let open: [Capture]
            do {
                open = try await notes.openCaptures().filter { $0.launchID != launchID }
            } catch {
                Say.fail("the open captures could not be read: \(error.code)")
            }
            guard let inbox = InboxEntries.list(locations, besides: capturing ? launchID : nil) else {
                Say.fail("Inbox/ could not be listed")
            }
            Say.line(
                SoakLine.recoveryLeft(open: open.count, inbox: inbox.others, partials: inbox.partials.count).rendered)
            for name in inbox.partials.sorted() { Say.line(SoakLine.inboxPartial(name).rendered) }
            for row in open { Say.line(SoakLine.leftOpen(row.id).rendered) }
            // `Recording/` too: a recording recovery finished leaves none of its files there.
            guard let recording = RecordingEntries.list(locations, besides: capturing ? launchID : nil) else {
                Say.fail("Recording/ could not be listed")
            }
            Say.line(
                SoakLine.recordingLeft(others: recording.others, peaksTemporaries: recording.peaksTemporaries.count)
                    .rendered)
            for name in recording.peaksTemporaries.sorted() { Say.line(SoakLine.peaksTemporary(name).rendered) }
        }
    }

    /// What the engine says of the frames of each recording of the launch, as its states come:
    /// each time more are durable, the parent is told.
    final class AudioWitness: Sendable {
        private struct Recording {
            let index: Int
            var frames: Int64
        }

        private let recordings = Mutex<[CaptureID: Recording]>([:])
        /// The fault `audioAcknowledgedAhead`: the parent is told of a second more audio than the
        /// engine said is durable.
        private let ahead: Bool

        init(ahead: Bool = false) { self.ahead = ahead }

        /// A recording that began, with the frames its start answered as durable.
        func begin(_ capture: CaptureID, index: Int, frames: Int64) {
            let first = recordings.withLock { recordings in
                let known = recordings[capture]?.frames ?? 0
                recordings[capture] = Recording(index: index, frames: max(known, frames))
                return max(known, frames)
            }
            say(index, capture, first, .open)
        }

        /// A state the engine published. Frames that come before the start answered wait for it.
        func observe(_ state: CaptureState) {
            guard state.outcome == .open else { return }
            let told: (Int, Int64)? = recordings.withLock { recordings in
                guard var recording = recordings[state.captureID], state.durableRevision > recording.frames else {
                    return nil
                }
                recording.frames = state.durableRevision
                recordings[state.captureID] = recording
                return (recording.index, recording.frames)
            }
            if let (index, frames) = told { say(index, state.captureID, frames, .open) }
        }

        /// How many frames are durable, as the engine said.
        func durable(_ capture: CaptureID) -> Int64 { recordings.withLock { $0[capture]?.frames ?? 0 } }

        /// The recording's end, as `end` or `discard` answered it.
        func end(_ capture: CaptureID, _ state: CaptureState) {
            guard let index = recordings.withLock({ $0[capture]?.index }) else { return }
            let discarded = state.outcome == .discardedEmpty
            say(index, capture, discarded ? 0 : state.durableRevision, discarded ? .discarded : .ended)
        }

        private func say(_ index: Int, _ capture: CaptureID, _ frames: Int64, _ state: SoakLine.Acknowledgement.State) {
            let frames = ahead && frames > 0 ? frames + Int64(SoakScript.sampleRate) : frames
            Say.line(
                SoakLine.ackAudio(
                    SoakLine.AudioAcknowledgement(index: index, capture: capture, frames: frames, state: state)
                ).rendered)
        }
    }

    final class SoakLaunch {
        struct Options {
            var root: URL
            var seed: UInt64
            var launch: Int
            var range: Range<Int>
            var count: Int
            var killPoint: String?
            var killAfter: Int
            var fault: InjectedFault?
        }

        private let options: Options
        private let script: SoakScript
        private let clock: FakeClock
        private let ids: SeededIDGenerator
        private let arming: KillArming
        private let locations: StoreLocations
        private let database: StoreDatabase
        private let notes: NoteRepository
        /// The store's assets, which the fault `recordingStoredTwice` writes to behind the engine.
        private let assets: AssetRepository
        private let engine: StandardCaptureEngine
        /// The processing queue, which each launch drains after recovery.
        private let queue: StandardProcessingQueue
        private let ingest: InboxIngest
        private let recovery: LaunchRecovery
        private let launchID: LaunchID

        /// The engine's deadline, which the script decides (`ScriptedDeadline`).
        private let scriptedDeadline = ScriptedDeadline()
        /// The write that `acknowledgementBeforeWrite` holds back, per capture.
        private var heldBack: [CaptureID: String] = [:]
        /// The durable revision the engine last answered, per capture.
        private var durable: [CaptureID: Int64] = [:]
        /// The captures that `vanishedCapture` answered and never wrote.
        private var vanished: Set<CaptureID> = []
        /// Whether this launch's captures run beside its recovery: the script then disturbs no write.
        private var capturesDuringRecovery = false
        /// What the engine says of each recording's durable frames.
        private lazy var audio = AudioWitness(ahead: options.fault == .audioAcknowledgedAhead)
        /// The capture the script left open, which the next one's start ends (rule 15).
        private var leftOpen: (index: Int, id: CaptureID, text: String)?

        init(_ options: Options) {
            self.options = options
            script = SoakScript(seed: options.seed, count: options.count)
            clock = FakeClock(SoakScript.base)
            // A seed of its own for each launch, so that no two launches make the same IDs.
            ids = SeededIDGenerator(seed: options.seed &+ UInt64(options.launch) &* 0x9E37_79B9_7F4A_7C15, clock: clock)
            arming = KillArming(point: options.killPoint, after: options.killAfter)
            locations = StoreLocations.testing(root: options.root)
            let log = KnotLog(.capture, sink: SoakLogSink(arming: arming))
            do {
                database = try StoreDatabase.open(
                    locations: locations, role: .app, clock: clock, ids: ids, hooks: arming.storeHooks)
            } catch {
                Say.fail("the store did not open: \(error.code)")
            }
            notes = NoteRepository(database: database)
            let layer = PosixFileLayer()
            assets = AssetRepository(locations: locations, layer: layer, database: database)
            let recorder = SoakRecorder(
                locations: locations, clock: clock, log: KnotLog(.audio, sink: SoakLogSink(arming: arming)),
                fault: options.fault)
            // Scripted speech and cleanup (`SoakSpeech`): no model, no hardware input. A run reads
            // two seconds, so a recording's transcription takes more than one run. The queue runs
            // the jobs of this device's segments, as the live composition's does.
            let queue = StandardProcessingQueue(
                notes: notes, assets: assets,
                transcriber: SoakTranscriber(wrong: options.fault == .transcriptNotTheScript),
                cleaner: SoakCleaner(twice: options.fault == .cleanupAppliedTwice), clock: clock, ids: ids,
                runBudget: .seconds(2), device: database.deviceID,
                log: log)
            self.queue = queue
            launchID = ids.make()
            ingest = InboxIngest(
                notes: notes, assets: assets, recorder: recorder, queue: queue, clock: clock, launchID: launchID,
                locations: locations, layer: layer, log: log)
            recovery = LaunchRecovery(
                notes: notes, assets: assets, recorder: recorder, queue: queue, launchID: launchID,
                locations: locations, layer: layer, log: log)
            let arming = arming
            engine = StandardCaptureEngine(
                notes: notes, assets: assets, recorder: recorder, queue: queue, clock: clock, ids: ids,
                deviceID: database.deviceID, launchID: launchID, locations: locations, layer: layer,
                deadline: scriptedDeadline.deadline, ingest: ingest, log: log,
                killPoint: { point, _ in await arming.reach("engine:\(point.rawValue)") },
                stopsInsideWrite: { point, _ in arming.stopsInsideWrite("engine:\(point.rawValue)") })
        }

        func run() async {
            Say.line(SoakLine.launch(options.launch).rendered)
            // Every state the engine publishes: a recording's durable frames come only so.
            let states = engine.states()
            let audio = audio
            Task.detached {
                for await state in states where state.kind == .voice { audio.observe(state) }
            }
            // The clock starts where this launch's part of the script starts, just before it.
            let first = script.captures.indices.contains(options.range.lowerBound) ? options.range.lowerBound : nil
            clock.set(SoakScript.base.addingTimeInterval((first.map { script.captures[$0].startsAt } ?? 0) - 1))
            let concurrent = Self.recoversWhileCapturing(seed: options.seed, launch: options.launch)
            let recovering = RecoveryRun(
                recovery: recovery, ingest: ingest, notes: notes, locations: locations, launchID: launchID,
                skipped: options.fault == .skippedRecovery, capturing: concurrent)
            if concurrent {
                // The app does not wait for recovery: typing starts at once. This launch's captures
                // begin while recovery runs. The script disturbs none of their writes, though the
                // store may still refuse one, as when it meets a row of a dead launch still open on
                // the device, and the item that capture takes in `Inbox/` is this launch's.
                capturesDuringRecovery = true
                async let recovered: Void = recovering.run()
                for index in options.range {
                    await runCapture(script.captures[index])
                }
                await recovered
                await process()
            } else {
                await recovering.run()
                await process()
                for index in options.range {
                    await runCapture(script.captures[index])
                }
            }
            // The launch ends as the app quits: the capture left open ends, and what the engine
            // left in `Inbox/` is ingested.
            if let open = leftOpen {
                leftOpen = nil
                await end(open.index, open.id, text: open.text, discard: false)
            }
            _ = await ingest.ingestAll()
            if options.fault == .recordingFileLeftAtEnd, options.range.isEmpty {
                let stray = locations.recording.appending(
                    path: "\(UUID().uuidString.lowercased()).caf", directoryHint: .notDirectory)
                FileManager.default.createFile(atPath: stray.path, contents: Data([0]))
            }
            // The app quits as a process does: its last line, then the exit, with the store as it
            // stands. Closing the store first would fail the engine's own work in flight, such as
            // an ingest it started, which the next launch finishes.
            Say.last(SoakLine.done.rendered)
            // The fault `errorLoggedAfterDone`: the engine's log writes an error after the last
            // line, from another task, as work still in flight at the exit would. The child says on
            // its standard error how many lines were refused, so a test sees the line was tried.
            if options.fault == .errorLoggedAfterDone {
                let log = KnotLog(.capture, sink: SoakLogSink(arming: arming))
                await Task.detached { log.failure(KnotError.storeBusy, "store_write_failed") }.value
                FileHandle.standardError.write(Data("KnotSoakChild: refused \(Say.refused) line after the last\n".utf8))
            }
            exit(0)
        }

        /// Drains the processing queue once recovery has run, as the app does at launch: it says
        /// which jobs an earlier launch left marked running, resumes the queue, which counts their
        /// deaths, and runs every job it can, awaited, so nothing of it runs after the last line.
        /// The last launch, which runs no capture, drains what every launch before it left.
        private func process() async {
            let last = options.range.isEmpty
            for job in (try? await notes.jobs(for: nil)) ?? [] where job.state == .running {
                Say.line(
                    SoakLine.foundRunning(
                        capture: CaptureID(job.segmentID), kind: job.kind.rawValue, deaths: job.deaths
                    )
                    .rendered)
                if options.fault == .deathNotCounted {
                    var requeued = job
                    requeued.state = .queued
                    _ = try? await notes.saveJob(requeued)
                }
            }
            if options.fault != .resumeSkipped { try? await queue.resume() }
            if options.fault == .deathLimitIgnored {
                for job in (try? await notes.jobs(for: nil)) ?? []
                where job.state == .failed(KnotError.jobDiedTwice.code) {
                    var again = job
                    again.state = .queued
                    _ = try? await notes.saveJob(again)
                }
            }
            if options.fault != .drainSkipped {
                _ = await queue.drain(using: StraightThroughRunner(), progress: { _ in })
            }
            if last { await injectAfterLastDrain() }
        }

        /// The faults of the processing queue's checks that the last launch writes.
        private func injectAfterLastDrain() async {
            let jobs = (try? await notes.jobs(for: nil)) ?? []
            let transcribe = jobs.first { $0.kind == .transcribe }
            switch options.fault {
            case .jobWrittenTwice?:
                if let transcribe {
                    _ = try? await notes.saveJob(
                        Job(id: ids.make(), segmentID: transcribe.segmentID, kind: .transcribe))
                }
            case .jobRowLost?:
                if let transcribe { FaultyStoreWrites.deleteJob(transcribe.id, in: locations) }
            case .jobOfATypedCapture?:
                if let segment = FaultyStoreWrites.typedSegment(in: locations) {
                    _ = try? await notes.saveJob(
                        Job(id: .transcribe(of: segment), segmentID: segment, kind: .transcribe))
                }
            case .deathAdded?:
                if var done = jobs.first(where: { $0.state == .done && $0.deaths == 0 }) {
                    done.deaths += 1
                    _ = try? await notes.saveJob(done)
                }
            case .cleanJobAfterFailure?:
                if let failed = jobs.first(where: { $0.kind == .transcribe && $0.state != .done }) {
                    _ = try? await notes.saveJob(
                        Job(id: .clean(of: failed.segmentID), segmentID: failed.segmentID, kind: .clean))
                }
            case .segmentStepLeft?:
                if let clean = jobs.first(where: { $0.kind == .clean && $0.state == .done }) {
                    _ = try? await notes.setState(.voice(.transcribed), of: clean.segmentID)
                }
            default:
                break
            }
        }

        /// Whether a launch begins its captures while its recovery runs: one in three, by the seed.
        /// The parent makes the same choice.
        static func recoversWhileCapturing(seed: UInt64, launch: Int) -> Bool {
            var random = SeededRandom(seed: seed ^ (UInt64(launch) &* 0xA24B_AED4_963E_E407))
            return random.next() % 3 == 0
        }

        // MARK: One capture

        private func runCapture(_ capture: SoakScript.Capture) async {
            if capture.kind == .voice {
                await runRecording(capture)
                return
            }
            let index = capture.index
            clock.set(SoakScript.base.addingTimeInterval(capture.startsAt))
            Say.line(SoakLine.intent(index).rendered)
            let begun: CaptureState
            do throws(KnotError) {
                begun = try await disturbed(capture, save: 0) { () async throws(KnotError) -> CaptureState in
                    if self.options.fault == .vanishedCapture, index % 5 == 2 {
                        let id: CaptureID = self.ids.make()
                        self.vanished.insert(id)
                        return self.answeredAhead(id)
                    }
                    return try await self.engine.begin(
                        CaptureRequest(
                            kind: .typed, surface: capture.surface, placement: capture.placement,
                            text: capture.texts[0]))
                }
            } catch {
                Say.line(SoakLine.refused(index: index, code: error.code.rawValue).rendered)
                // The capture left open stays so: it ends by itself, as the app would end it.
                if let open = leftOpen {
                    leftOpen = nil
                    await end(open.index, open.id, text: open.text, discard: false)
                }
                return
            }
            // Rule 15 ended the capture left open, at this one's start: its last acknowledged
            // save stands.
            leftOpen = nil
            let id = begun.captureID
            acknowledge(index, save: 0, begun, text: capture.texts[0], state: "open")
            await arming.step("after_begin")
            for save in capture.texts.indices.dropFirst() {
                clock.advance(by: capture.pauses[save - 1])
                let text = capture.texts[save]
                let isLast = save == capture.texts.count - 1 && capture.ending == .end
                do throws(KnotError) {
                    let state = try await disturbed(capture, save: save) { () async throws(KnotError) -> CaptureState in
                        try await self.update(id, text: text, isLastBeforeEnd: isLast)
                    }
                    acknowledge(index, save: save, state, text: text, state: "open")
                } catch {
                    Say.line(SoakLine.refused(index: index, code: error.code.rawValue).rendered)
                }
                await arming.step("after_checkpoint")
            }
            clock.advance(by: capture.pauses.last ?? 0)
            switch capture.ending {
            case .leftOpen:
                leftOpen = (index, id, capture.texts.last ?? "")
            case .end, .discard:
                await end(index, id, text: capture.texts.last ?? "", discard: capture.ending == .discard)
            }
        }

        /// A recording on the live recorder, through the engine as the app records: it begins,
        /// records until the script's frames are durable, as the engine says, and ends, or is
        /// discarded as an accidental press.
        private func runRecording(_ capture: SoakScript.Capture) async {
            let index = capture.index
            clock.set(SoakScript.base.addingTimeInterval(capture.startsAt))
            Say.line(SoakLine.intent(index).rendered)
            let begun: CaptureState
            do throws(KnotError) {
                begun = try await disturbed(capture, save: 0) { () async throws(KnotError) -> CaptureState in
                    try await self.engine.begin(
                        CaptureRequest(kind: .voice, surface: capture.surface, placement: capture.placement))
                }
            } catch {
                Say.line(SoakLine.refused(index: index, code: error.code.rawValue).rendered)
                if let open = leftOpen {
                    leftOpen = nil
                    await end(open.index, open.id, text: open.text, discard: false)
                }
                return
            }
            // Rule 15 ended the typed capture left open: a recording is of another kind.
            leftOpen = nil
            let id = begun.captureID
            audio.begin(id, index: index, frames: begun.durableRevision)
            await arming.step("after_begin")
            // It records until the script's frames are durable, each new durable stretch a pass of
            // the step `during_recording`, or for at most half a minute. A stretch that ends the
            // wait is a pass too, while the recording is still open: so every recording with a
            // durable frame passes the step at least once, however the recorder's syncs fall.
            var seen: Int64 = 0
            let until = ContinuousClock.now + .seconds(30)
            while audio.durable(id) < capture.frames, ContinuousClock.now < until {
                let now = audio.durable(id)
                if now > seen {
                    seen = now
                    await arming.step("during_recording")
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            if audio.durable(id) > seen { await arming.step("during_recording") }
            clock.advance(by: capture.pauses.last ?? 0)
            let discard = capture.ending == .discard
            if discard { Say.line(SoakLine.discarding(index: index, capture: id).rendered) }
            // The fault `recordingEndDiscarded`: the script ends the recording, and the engine
            // discards it, unsaid.
            let lost = !discard && options.fault == .recordingEndDiscarded && index % 2 == 1
            do throws(KnotError) {
                let state = try await disturbed(capture, save: 1) { () async throws(KnotError) -> CaptureState in
                    discard || lost ? try await self.engine.discard(id) : try await self.engine.end(id)
                }
                audio.end(id, state)
                if state.outcome == .stored { await injectAfterRecording(capture, id) }
            } catch {
                Say.line(SoakLine.refused(index: index, code: error.code.rawValue).rendered)
            }
            // The fault `afterEndNeverPassed`: a point of the list that the child never reaches.
            if options.fault != .afterEndNeverPassed { await arming.step("after_end") }
        }

        private func injectAfterRecording(_ capture: SoakScript.Capture, _ id: CaptureID) async {
            guard capture.index % 2 == 1 else { return }
            switch options.fault {
            case .recordingFileLost?: FaultyStoreWrites.loseAsset(of: id, in: locations)
            case .assetFileOrphaned?: FaultyStoreWrites.orphanAsset(beside: id, in: locations)
            case .recordingRowLost?: FaultyStoreWrites.deleteCaptureRow(id, in: locations)
            case .recordingStoredTwice?: await storeAgain(capture, id)
            default: break
            }
        }

        /// The fault `recordingStoredTwice`: the recording is stored again under a new capture
        /// ID, with a copy of its file and its start, in a note of its own.
        private func storeAgain(_ capture: SoakScript.Capture, _ id: CaptureID) async {
            let other: CaptureID = ids.make()
            let copy = locations.recording.appending(path: "\(other).m4a", directoryHint: .notDirectory)
            guard (try? FileManager.default.copyItem(at: locations.asset(AssetID(id), kind: .audio), to: copy)) != nil,
                let moved = try? await assets.move(copy, as: AssetID(other), kind: .audio)
            else { Say.fail("the injected fault could not copy a recording") }
            let startedAt = SoakScript.base.addingTimeInterval(capture.startsAt)
            let asset = Asset(
                id: AssetID(other), segmentID: SegmentID(other), kind: .audio, byteCount: moved.byteCount,
                sha256: moved.sha256)
            _ = try? await notes.record(
                NewCapture(
                    id: other, kind: .voice, origin: CaptureOrigin(source: .device(database.deviceID), surface: .app),
                    launchID: launchID, placement: .newNote, startedAt: startedAt, endedAt: clock.now(),
                    body: .file(asset, duration: .seconds(Double(capture.frames) / SoakScript.sampleRate))))
        }

        private func end(_ index: Int, _ id: CaptureID, text: String, discard: Bool) async {
            let capture = script.captures[index]
            // Said before the call: a discard that commits before a kill has kept nothing, and
            // rightly so.
            if discard { Say.line(SoakLine.discarding(index: index, capture: id).rendered) }
            // The fault `typedEndDiscarded`: the script ends the capture, and the engine discards
            // it, unsaid.
            let lost = !discard && options.fault == .typedEndDiscarded && index % 2 == 1 && !capture.blank
            do throws(KnotError) {
                let state = try await disturbed(capture, save: capture.texts.count) {
                    () async throws(KnotError) -> CaptureState in
                    if self.vanished.contains(id) {
                        var state = self.answeredAhead(id)
                        state.outcome = discard ? .discardedEmpty : .stored
                        return state
                    }
                    try await self.flushHeldBack(id)
                    return discard || lost ? try await self.engine.discard(id) : try await self.engine.end(id)
                }
                let discarded = state.outcome == .discardedEmpty
                acknowledge(
                    index, save: capture.texts.count, state, text: discarded ? "" : text,
                    state: discarded ? "discarded" : "ended")
                if state.outcome == .stored { await injectAfterStore(index, id, text: text) }
            } catch {
                Say.line(SoakLine.refused(index: index, code: error.code.rawValue).rendered)
            }
            // The fault `afterEndNeverPassed`: a point of the list that the child never reaches.
            if options.fault != .afterEndNeverPassed { await arming.step("after_end") }
        }

        // MARK: The engine, and the faults the soak's tests inject

        private func update(_ id: CaptureID, text: String, isLastBeforeEnd: Bool) async throws(KnotError)
            -> CaptureState
        {
            if vanished.contains(id) { return answeredAhead(id) }
            switch options.fault {
            case .acknowledgementBeforeWrite?:
                try await flushHeldBack(id)
                heldBack[id] = text
                return answeredAhead(id)
            case .droppedLastCheckpoint? where isLastBeforeEnd:
                return answeredAhead(id)
            default:
                return try await engine.update(id, with: .text(text))
            }
        }

        /// A state that says the next revision is durable, which the engine never said.
        private func answeredAhead(_ id: CaptureID) -> CaptureState {
            CaptureState(
                captureID: id, kind: .typed, noteID: nil, outcome: .open, path: .store,
                durableRevision: (durable[id] ?? 0) + 1)
        }

        private func flushHeldBack(_ id: CaptureID) async throws(KnotError) {
            guard let text = heldBack.removeValue(forKey: id) else { return }
            _ = try await engine.update(id, with: .text(text))
        }

        private func injectAfterStore(_ index: Int, _ id: CaptureID, text: String) async {
            guard index % 3 == 1 else { return }
            switch options.fault {
            case .skippedCaptureRow?:
                FaultyStoreWrites.deleteCaptureRow(id, in: locations)
            case .captureStoredTwice?:
                let now = clock.now()
                _ = try? await notes.record(
                    NewCapture(
                        id: ids.make(), kind: .typed,
                        origin: CaptureOrigin(source: .device(database.deviceID), surface: .app), launchID: launchID,
                        placement: .newNote, startedAt: now, endedAt: now, body: .text(text)))
            default:
                break
            }
        }

        /// Runs one save of `capture`, with the disturbance the script gives that save: the store
        /// refuses it as busy, or holds it past the engine's deadline and lets it commit after.
        private func disturbed(
            _ capture: SoakScript.Capture, save: Int, _ body: () async throws(KnotError) -> CaptureState
        ) async throws(KnotError) -> CaptureState {
            guard !capturesDuringRecovery, let disturbance = capture.disturbance, disturbance.save == save else {
                return try await body()
            }
            switch disturbance.kind {
            case .refused:
                await notes.failNextCaptureWrites(with: .storeBusy)
                return try await body()
            case .held:
                let hold = await notes.holdNextCaptureWrite()
                scriptedDeadline.expires(true)
                defer {
                    scriptedDeadline.expires(false)
                    hold.release()
                }
                return try await body()
            }
        }

        private func acknowledge(_ index: Int, save: Int, _ state: CaptureState, text: String, state name: String) {
            guard state.durableRevision > 0 || name != "open" else { return }
            durable[state.captureID] = max(durable[state.captureID] ?? 0, state.durableRevision)
            let bytes = Data(text.utf8)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            Say.line(
                SoakLine.ack(
                    SoakLine.Acknowledgement(
                        index: index, save: save, capture: state.captureID, revision: state.durableRevision,
                        bytes: bytes.count,
                        digest: digest, state: SoakLine.Acknowledgement.State(rawValue: name) ?? .open,
                        blank: text.allSatisfy { $0 == " " || $0 == "\n" })
                ).rendered)
        }
    }
#endif
