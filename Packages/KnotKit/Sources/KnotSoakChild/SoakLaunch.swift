#if DEBUG || KNOT_FAKES
    import CryptoKit
    import Foundation
    import KnotCapture
    import KnotCore
    import KnotFakes
    import KnotStore

    /// One launch of the soak's child over the real store (docs/architecture.md §17): it
    /// composes the store, the capture engine, ingest and recovery as the app does, over the
    /// scripted recorder, transcriber and cleaner and an injected clock; it recovers what the
    /// launches before it left; then it runs its part of the script, and tells its parent each
    /// save the engine acknowledged.
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
        private let engine: StandardCaptureEngine
        private let ingest: InboxIngest
        private let recovery: LaunchRecovery
        private let launchID: LaunchID

        /// The write that `acknowledgementBeforeWrite` holds back, per capture.
        private var heldBack: [CaptureID: String] = [:]
        /// The durable revision the engine last answered, per capture.
        private var durable: [CaptureID: Int64] = [:]
        /// The captures that `vanishedCapture` answered and never wrote.
        private var vanished: Set<CaptureID> = []
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
            let assets = AssetRepository(locations: locations, layer: layer, database: database)
            let recorder = ScriptedRecorder(locations: locations, layer: layer, clock: clock)
            let queue = StandardProcessingQueue(
                notes: notes, assets: assets, transcriber: ScriptedTranscriber(), cleaner: ScriptedCleaner(),
                clock: clock, ids: ids, log: log)
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
                deadline: .standard, ingest: ingest, log: log,
                killPoint: { point, _ in await arming.reach("engine:\(point.rawValue)") })
        }

        func run() async {
            Say.line(SoakLine.launch(options.launch).rendered)
            // The clock starts where this launch's part of the script starts, just before it.
            let first = script.captures.indices.contains(options.range.lowerBound) ? options.range.lowerBound : nil
            clock.set(SoakScript.base.addingTimeInterval((first.map { script.captures[$0].startsAt } ?? 0) - 1))
            if options.fault == .skippedRecovery {
                Say.line(SoakLine.recovered(0).rendered)
            } else {
                do {
                    let outcomes = try await recovery.run(ingest: ingest)
                    Say.line(SoakLine.recovered(outcomes.count).rendered)
                } catch {
                    Say.fail("recovery failed: \(error.code)")
                }
            }
            for index in options.range {
                await runCapture(script.captures[index])
            }
            // The launch ends as the app quits: the capture left open ends, and what the engine
            // left in `Inbox/` is ingested.
            if let open = leftOpen {
                leftOpen = nil
                await end(open.index, open.id, text: open.text, discard: false)
            }
            _ = await ingest.ingestAll()
            Say.line(SoakLine.done.rendered)
            try? database.close()
        }

        // MARK: One capture

        private func runCapture(_ capture: SoakScript.Capture) async {
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

        private func end(_ index: Int, _ id: CaptureID, text: String, discard: Bool) async {
            let capture = script.captures[index]
            // Said before the call: a discard that commits before a kill has kept nothing, and
            // rightly so.
            if discard { Say.line(SoakLine.discarding(index: index, capture: id).rendered) }
            do throws(KnotError) {
                let state = try await disturbed(capture, save: capture.texts.count) {
                    () async throws(KnotError) -> CaptureState in
                    if self.vanished.contains(id) {
                        var state = self.answeredAhead(id)
                        state.outcome = discard ? .discardedEmpty : .stored
                        return state
                    }
                    try await self.flushHeldBack(id)
                    return discard ? try await self.engine.discard(id) : try await self.engine.end(id)
                }
                let discarded = state.outcome == .discardedEmpty
                acknowledge(
                    index, save: capture.texts.count, state, text: discarded ? "" : text,
                    state: discarded ? "discarded" : "ended")
                if state.outcome == .stored { await injectAfterStore(index, id, text: text) }
            } catch {
                Say.line(SoakLine.refused(index: index, code: error.code.rawValue).rendered)
            }
            await arming.step("after_end")
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
            guard let disturbance = capture.disturbance, disturbance.save == save else { return try await body() }
            switch disturbance.kind {
            case .refused:
                await notes.failNextCaptureWrites(with: .storeBusy)
                return try await body()
            case .held:
                let hold = await notes.holdNextCaptureWrite()
                defer { hold.release() }
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
