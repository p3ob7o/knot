#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore
    import Synchronization

    /// A pair of devices and the system between them, for tests and previews: what
    /// `WCSession` does, as docs/notes/SP-2.md found it, driven step by step by a test.
    ///
    /// The system outlives each app's launch, as the real one does. `launch(_:)` gives one
    /// launch of the Watch app or the iPhone app its `FakeLinkTransport`; a later `launch` of
    /// the same side ends the earlier one. Transfers still outstanding survive a relaunch, and
    /// the ends of transfers that finished while no launch was activated arrive at the next
    /// launch, straight after its activation, in order.
    ///
    /// Nothing moves by itself. A test ends each transfer with `finish(_:attempt:as:)`: it
    /// arrives, arrives damaged, finishes without arriving, or fails. Every event then waits in
    /// the network, and is given to the app at once unless `holdsEvents` is set. A test that
    /// holds events can lose, repeat and reorder them with `releaseHeld(_:_:)`, events of each
    /// kind alike. A cancel is reported by the transport itself, so it is never held.
    public final class FakeLinkSystem: Sendable {
        public enum Side: Hashable, Sendable {
            case watch
            case phone

            var other: Side { self == .watch ? .phone : .watch }
        }

        /// How a transfer ends.
        public enum Fate: Hashable, Sendable {
            /// The file reaches the iPhone app's receiver whole, and the sender hears that it
            /// finished.
            case arrives
            /// The file reaches the receiver with one byte changed.
            case arrivesDamaged
            /// The sender hears that it finished without an error, and nothing arrives, as in
            /// the simulator.
            case neverArrives
            /// The transfer fails.
            case fails(LinkFailure)
        }

        struct Transfer: Sendable {
            var captureID: CaptureID
            var attempt: Int
            var url: URL
            var manifest: Data
            var from: Side
        }

        struct State: Sendable {
            var sessions: [Side: LinkSessionState] = [.watch: .ready, .phone: .ready]
            var outstanding: [Transfer] = []
            var network: [Side: [LinkEvent]] = [.watch: [], .phone: []]
            var launches: [Side: FakeLinkTransport] = [:]
            var activated: Set<ObjectIdentifier> = []
            var activationWaiters: [ObjectIdentifier: [CheckedContinuation<LinkSessionState, Never>]] = [:]
            var activatesByItself = true
            var holdsEvents = false
            var receiver: (@Sendable (ReceivedFile) -> LinkMessage?)?
            var context: LinkContext?
            var queuedCount: [CaptureID: Int] = [:]
            var arrivals: [CaptureID: Int] = [:]
            var cancels: [CaptureID: Int] = [:]
            var receivedSerial = 0
        }

        let state = Mutex(State())
        /// Where the iPhone's side gets each received file until its receiver returns.
        let receiving: URL

        /// - Parameter receiving: a folder for received files, which the system deletes after
        ///   the receiver returns, as the real one does.
        public init(receiving: URL) {
            self.receiving = receiving
        }

        /// A new launch of one side's app. The earlier launch of that side ends.
        public func launch(_ side: Side) -> FakeLinkTransport {
            let transport = FakeLinkTransport(system: self, side: side)
            let earlier = state.withLock { state in
                let earlier = state.launches[side]
                state.launches[side] = transport
                if side == .phone { state.receiver = nil }
                return earlier
            }
            earlier?.end()
            return transport
        }

        // MARK: Scripting

        /// When false, `activate()` waits for `completeActivation(_:)`.
        public var activatesByItself: Bool {
            get { state.withLock { $0.activatesByItself } }
            set { state.withLock { $0.activatesByItself = newValue } }
        }

        /// When true, events wait in the network until `releaseHeld(_:_:)`.
        public var holdsEvents: Bool {
            get { state.withLock { $0.holdsEvents } }
            set { state.withLock { $0.holdsEvents = newValue } }
        }

        /// Runs the activation callback of the current launch of `side`.
        public func completeActivation(_ side: Side) {
            guard let launch = state.withLock({ $0.launches[side] }) else { return }
            activate(launch)
        }

        /// Sets one side's session state, and tells that side's app.
        public func setState(_ session: LinkSessionState, of side: Side) {
            state.withLock { $0.sessions[side] = session }
            emit(.stateChanged(session), to: side)
        }

        /// The transfers that one side has queued and that have not ended.
        public func outstanding(from side: Side = .watch) -> [OutstandingFile] {
            state.withLock { state in
                state.outstanding.filter { $0.from == side }.map {
                    OutstandingFile(captureID: $0.captureID, attempt: $0.attempt)
                }
            }
        }

        /// Ends a transfer: the given attempt, or the capture's latest. False when there is
        /// no such transfer.
        @discardableResult
        public func finish(_ capture: CaptureID, attempt: Int? = nil, as fate: Fate) -> Bool {
            let transfer: Transfer? = state.withLock { state in
                let index = state.outstanding.lastIndex {
                    $0.captureID == capture && (attempt == nil || $0.attempt == attempt)
                }
                return index.map { state.outstanding.remove(at: $0) }
            }
            guard let transfer else { return false }
            end(transfer, as: fate)
            return true
        }

        /// Ends every outstanding transfer of one side, in the order they were queued.
        public func finishAll(from side: Side = .watch, as fate: Fate) {
            let transfers = state.withLock { state in
                let mine = state.outstanding.filter { $0.from == side }
                state.outstanding.removeAll { $0.from == side }
                return mine
            }
            for transfer in transfers { end(transfer, as: fate) }
        }

        /// The events that wait in the network for one side's app.
        public func held(for side: Side = .watch) -> [LinkEvent] {
            state.withLock { $0.network[side] ?? [] }
        }

        /// Gives one side's app the events that `arrange` makes of those held for it: in
        /// another order, some left out, some twice. Those it leaves out are lost.
        public func releaseHeld(_ side: Side = .watch, _ arrange: ([LinkEvent]) -> [LinkEvent] = { $0 }) {
            let events = state.withLock { state in
                defer { state.network[side] = [] }
                return state.network[side] ?? []
            }
            deliver(arrange(events), to: side)
        }

        /// Sends the context from the iPhone, as the phone's app would.
        public func pushContext(_ context: LinkContext) {
            state.withLock { $0.context = context }
            emit(.context(context), to: .watch)
        }

        /// How many times a capture was queued, by every launch together.
        public func timesQueued(_ capture: CaptureID) -> Int { state.withLock { $0.queuedCount[capture] ?? 0 } }

        /// How many times a capture's file reached the iPhone app's receiver.
        public func arrivals(_ capture: CaptureID) -> Int { state.withLock { $0.arrivals[capture] ?? 0 } }

        /// How many transfers of a capture were cancelled.
        public func timesCancelled(_ capture: CaptureID) -> Int { state.withLock { $0.cancels[capture] ?? 0 } }

        // MARK: What the transports call

        func activate(_ launch: FakeLinkTransport) {
            let id = ObjectIdentifier(launch)
            let (waiters, session, current) = state.withLock { state in
                state.activated.insert(id)
                let waiters = state.activationWaiters.removeValue(forKey: id) ?? []
                return (waiters, state.sessions[launch.side] ?? .inactive, state.launches[launch.side] === launch)
            }
            for waiter in waiters { waiter.resume(returning: session) }
            // What finished while the app was not running arrives straight after activation.
            if current, !holdsEvents { releaseHeld(launch.side) }
        }

        func waitForActivation(_ launch: FakeLinkTransport) async -> LinkSessionState {
            let id = ObjectIdentifier(launch)
            return await withCheckedContinuation { continuation in
                let (ready, byItself, session) = state.withLock { state in
                    let ready = state.activated.contains(id)
                    if !ready { state.activationWaiters[id, default: []].append(continuation) }
                    return (ready, state.activatesByItself, state.sessions[launch.side] ?? .inactive)
                }
                if ready {
                    continuation.resume(returning: session)
                } else if byItself {
                    activate(launch)
                }
            }
        }

        func session(of side: Side) -> LinkSessionState { state.withLock { $0.sessions[side] ?? .inactive } }

        func isActivated(_ launch: FakeLinkTransport) -> Bool {
            state.withLock { $0.activated.contains(ObjectIdentifier(launch)) }
        }

        func queue(_ url: URL, manifest: CaptureManifest, attempt: Int, from side: Side) {
            state.withLock { $0.queuedCount[manifest.captureID, default: 0] += 1 }
            guard let data = try? manifest.encoded(), FileManager.default.fileExists(atPath: url.path) else {
                // A file that is not there fails at once, as WCErrorDomain 7013 does.
                emit(
                    .fileFinished(captureID: manifest.captureID, attempt: attempt, failure: .outboxFileMissing),
                    to: side)
                return
            }
            state.withLock {
                $0.outstanding.append(
                    Transfer(captureID: manifest.captureID, attempt: attempt, url: url, manifest: data, from: side))
            }
        }

        func cancel(_ capture: CaptureID, attempt: Int, from launch: FakeLinkTransport) {
            let removed = state.withLock { state in
                let before = state.outstanding.count
                state.outstanding.removeAll {
                    $0.captureID == capture && $0.attempt == attempt && $0.from == launch.side
                }
                let removed = state.outstanding.count < before
                if removed { state.cancels[capture, default: 0] += 1 }
                return removed
            }
            // The session never reports a cancel: the transport does, at once.
            if removed { launch.yield(.fileCancelled(captureID: capture, attempt: attempt)) }
        }

        func setReceiver(_ receive: @escaping @Sendable (ReceivedFile) -> LinkMessage?, from side: Side) {
            guard side == .phone else { return }
            state.withLock { $0.receiver = receive }
        }

        func send(_ message: LinkMessage, from side: Side) {
            emit(.message(message), to: side.other)
        }

        func updateContext(_ context: LinkContext, from side: Side) {
            guard side == .phone else { return }
            pushContext(context)
        }

        func receivedContext(for side: Side) -> LinkContext? {
            side == .watch ? state.withLock { $0.context } : nil
        }

        // MARK: Inside the system

        private func end(_ transfer: Transfer, as fate: Fate) {
            let capture = transfer.captureID
            switch fate {
            case .fails(let failure):
                emit(.fileFinished(captureID: capture, attempt: transfer.attempt, failure: failure), to: transfer.from)
            case .neverArrives:
                emit(.fileFinished(captureID: capture, attempt: transfer.attempt, failure: nil), to: transfer.from)
            case .arrives, .arrivesDamaged:
                guard var bytes = try? Data(contentsOf: transfer.url) else {
                    emit(
                        .fileFinished(captureID: capture, attempt: transfer.attempt, failure: .outboxFileMissing),
                        to: transfer.from)
                    return
                }
                if fate == .arrivesDamaged {
                    if bytes.isEmpty { bytes.append(0) } else { bytes[bytes.startIndex] ^= 0xFF }
                }
                let reply = receive(bytes, manifest: transfer.manifest, capture: capture)
                emit(.fileFinished(captureID: capture, attempt: transfer.attempt, failure: nil), to: transfer.from)
                if let reply { emit(.message(reply), to: transfer.from) }
            }
        }

        /// Hands the received file to the receiver, and deletes it when the receiver returns.
        private func receive(_ bytes: Data, manifest: Data, capture: CaptureID) -> LinkMessage? {
            let (receiver, serial) = state.withLock { state in
                state.receivedSerial += 1
                return (state.receiver, state.receivedSerial)
            }
            // With no iPhone app to take it, the file is dropped, as the simulator dropped
            // files for an app it counted as not installed.
            guard let receiver else { return nil }
            state.withLock { $0.arrivals[capture, default: 0] += 1 }
            try? FileManager.default.createDirectory(at: receiving, withIntermediateDirectories: true)
            let url = receiving.appending(path: "received-\(serial).m4a", directoryHint: .notDirectory)
            guard (try? bytes.write(to: url)) != nil else { return nil }
            defer { try? FileManager.default.removeItem(at: url) }
            return receiver(ReceivedFile(url: url, manifest: manifest))
        }

        /// Puts an event in the network for one side, and gives it to that side's activated
        /// launch at once unless events are held.
        private func emit(_ event: LinkEvent, to side: Side) {
            state.withLock { $0.network[side, default: []].append(event) }
            let release = state.withLock { state in
                guard !state.holdsEvents, let launch = state.launches[side] else { return false }
                return state.activated.contains(ObjectIdentifier(launch))
            }
            if release { releaseHeld(side) }
        }

        /// Gives events to the current launch of a side. With no activated launch, they wait
        /// for the next one.
        private func deliver(_ events: [LinkEvent], to side: Side) {
            let launch = state.withLock { state -> FakeLinkTransport? in
                guard let launch = state.launches[side], state.activated.contains(ObjectIdentifier(launch)) else {
                    state.network[side, default: []].insert(contentsOf: events, at: 0)
                    return nil
                }
                return launch
            }
            guard let launch else { return }
            for event in events { launch.yield(event) }
        }
    }

    /// One launch's view of a `FakeLinkSystem`.
    public final class FakeLinkTransport: LinkTransport {
        public let system: FakeLinkSystem
        public let side: FakeLinkSystem.Side
        public let events: AsyncStream<LinkEvent>
        private let continuation: AsyncStream<LinkEvent>.Continuation
        private let ended = Mutex(false)
        private let yielded = Mutex(0)

        init(system: FakeLinkSystem, side: FakeLinkSystem.Side) {
            self.system = system
            self.side = side
            (events, continuation) = AsyncStream.makeStream(of: LinkEvent.self)
        }

        func yield(_ event: LinkEvent) {
            yielded.withLock { $0 += 1 }
            continuation.yield(event)
        }

        /// How many events this launch has been given.
        public var eventsYielded: Int { yielded.withLock { $0 } }

        /// This launch ended: its app is gone, and what it still calls does nothing.
        func end() {
            ended.withLock { $0 = true }
            continuation.finish()
        }

        /// True once a later launch of the same side replaced this one.
        public var hasEnded: Bool { ended.withLock { $0 } }

        public func activate() async -> LinkSessionState {
            await system.waitForActivation(self)
        }

        public var state: LinkSessionState {
            system.isActivated(self) ? system.session(of: side) : .inactive
        }

        public var receivedContext: LinkContext? { system.receivedContext(for: side) }

        public func queueFile(_ url: URL, manifest: CaptureManifest, attempt: Int) {
            guard !hasEnded else { return }
            system.queue(url, manifest: manifest, attempt: attempt, from: side)
        }

        public func outstandingFiles() -> [OutstandingFile] { system.outstanding(from: side) }

        public func cancelFile(captureID: CaptureID, attempt: Int) {
            guard !hasEnded else { return }
            system.cancel(captureID, attempt: attempt, from: self)
        }

        public func setFileReceiver(_ receive: @escaping @Sendable (ReceivedFile) -> LinkMessage?) {
            system.setReceiver(receive, from: side)
        }

        public func send(_ message: LinkMessage) {
            guard !hasEnded else { return }
            system.send(message, from: side)
        }

        public func updateContext(_ context: LinkContext) throws(KnotError) {
            system.updateContext(context, from: side)
        }
    }
#endif
