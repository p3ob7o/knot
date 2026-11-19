import Foundation
import Observation
import WatchConnectivity
import os

/// One attempt to send one file, as the Watch saw it.
struct WatchTransfer: Codable, Sendable, Identifiable {
    var id: String { "\(manifest.id)#\(manifest.attempt)" }
    var manifest: TransferManifest
    var fileName: String
    var firstProgressAt: Date?
    var lastProgressAt: Date?
    var lastCompleted: Int64 = 0
    var totalUnits: Int64 = 0
    var finishedAt: Date?
    var finishError: String?
    var ackedAt: Date?
    var checksumOK: Bool?
    var stalls: Int = 0
    var inStall: Bool = false
    var cancelled: Bool = false
    /// Found in `outstandingFileTransfers` after the app was relaunched.
    var adoptedAfterRelaunch: Bool = false
}

/// A run of generated transfers that the Watch makes by itself.
struct TransferRun: Codable, Sendable {
    enum Mode: String, Codable, Sendable {
        /// The next file goes when the phone has acknowledged the previous one. Each timing
        /// is then one file alone on the link.
        case sequential
        /// Every file is queued at once. The system delivers them when it can, also after
        /// this app is suspended.
        case burst
    }

    var runID: String
    var count: Int
    var byteCount: Int
    var mode: Mode
    var nextSeq: Int
    var startedAt: Date
}

/// The Watch's side of `WCSession`: sends files, watches their progress, takes the phone's
/// acknowledgements, and keeps every outbox file until its capture ID is acknowledged.
@MainActor @Observable
final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()

    private(set) var activation = "not activated"
    private(set) var reachable = false
    private(set) var companionInstalled = false
    private(set) var hasContentPending = false
    private(set) var transfers: [WatchTransfer] = []
    private(set) var run: TransferRun?
    private(set) var lastContext: ContextPayload?
    private(set) var lastTranscribed: Transcribed?
    /// A transfer with no progress for this long counts as stalled.
    var stallSeconds: Double = 30
    /// Cancel a stalled transfer and queue the file again, as docs/architecture.md §12 plans.
    var requeueOnStall = false

    @ObservationIgnored private var live: [String: WCSessionFileTransfer] = [:]
    @ObservationIgnored private let store = JSONFile<[WatchTransfer]>("watch-transfers.json")
    @ObservationIgnored private let runStore = JSONFile<TransferRun>("watch-run.json")
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var activationWaiters: [CheckedContinuation<Void, Never>] = []
    /// Set by the delegate's activation callback. `activationState` can read "activated"
    /// before that callback has run, while `isReachable` is still false.
    @ObservationIgnored private var didActivate = false
    @ObservationIgnored private var probeSeq = 0
    @ObservationIgnored private var contextSeq = 0
    /// The order in which delegate callbacks arrived, counted on the delegate's own queue.
    nonisolated private let callbackCounter = OSAllocatedUnfairLock(initialState: 0)

    private let log = EventLog.shared

    override private init() {
        super.init()
        transfers = store.load() ?? []
        run = runStore.load()
    }

    // MARK: Session

    func activate() {
        guard WCSession.isSupported() else {
            activation = "not supported"
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
        log.append("watch.activate.called", ["uptime": String(format: "%.3f", ProcessClock.uptime)])
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    func waitUntilActivated() async {
        if didActivate { return }
        await withCheckedContinuation { activationWaiters.append($0) }
    }

    /// The `.backgroundTask(.watchConnectivity)` handler: the system woke the app for
    /// WatchConnectivity data. The task ends when this returns, so it waits until the
    /// session has nothing more to deliver, at most 15 seconds.
    func drainPendingContent() async {
        log.append("watch.wc-background-task.start", ["pending": "\(WCSession.default.hasContentPending)"])
        if WCSession.default.delegate == nil { activate() }
        await waitUntilActivated()
        let deadline = Date().addingTimeInterval(15)
        while WCSession.default.hasContentPending, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        log.append("watch.wc-background-task.end", ["pending": "\(WCSession.default.hasContentPending)"])
    }

    private func refreshState() {
        let session = WCSession.default
        activation = Self.name(session.activationState)
        reachable = session.isReachable
        companionInstalled = session.isCompanionAppInstalled
        hasContentPending = session.hasContentPending
    }

    private static func name(_ state: WCSessionActivationState) -> String {
        switch state {
        case .activated: "activated"
        case .inactive: "inactive"
        case .notActivated: "not activated"
        @unknown default: "unknown \(state.rawValue)"
        }
    }

    private func activated(_ state: WCSessionActivationState, error: String?) {
        refreshState()
        didActivate = true
        log.append(
            "watch.activation", ["state": Self.name(state), "error": error ?? "", "reachable": "\(reachable)"])
        adoptOutstanding()
        let waiters = activationWaiters
        activationWaiters = []
        waiters.forEach { $0.resume() }
        if let context = SP2.decode(
            ContextPayload.self, from: WCSession.default.receivedApplicationContext, key: SP2.contextKey)
        {
            lastContext = context
            log.append("watch.context.at-activation", ["seq": "\(context.seq)"])
        }
    }

    /// After a relaunch the system still holds the transfers queued before it. They come
    /// back as new objects in `outstandingFileTransfers`.
    private func adoptOutstanding() {
        let outstanding = WCSession.default.outstandingFileTransfers
        var adopted = 0
        for transfer in outstanding {
            guard
                let manifest = SP2.decode(
                    TransferManifest.self, from: transfer.file.metadata, key: SP2.manifestKey)
            else { continue }
            let key = "\(manifest.id)#\(manifest.attempt)"
            if live[key] == nil {
                live[key] = transfer
                adopted += 1
                if let index = transfers.firstIndex(where: { $0.id == key }) {
                    transfers[index].adoptedAfterRelaunch = true
                } else {
                    var record = WatchTransfer(manifest: manifest, fileName: transfer.file.fileURL.lastPathComponent)
                    record.adoptedAfterRelaunch = true
                    transfers.append(record)
                }
            }
        }
        log.append(
            "watch.outstanding", ["count": "\(outstanding.count)", "adopted": "\(adopted)"])
        save()
    }

    // MARK: Sending

    var waitingCount: Int {
        Set(transfers.filter { $0.checksumOK != true }.map(\.manifest.id))
            .subtracting(transfers.filter { $0.checksumOK == true }.map(\.manifest.id)).count
    }

    func startRun(count: Int, byteCount: Int, mode: TransferRun.Mode) {
        let run = TransferRun(
            runID: String(UUID().uuidString.prefix(8)), count: count, byteCount: byteCount, mode: mode, nextSeq: 1,
            startedAt: .now)
        self.run = run
        runStore.save(run)
        log.append(
            "watch.run.start",
            ["run": run.runID, "count": "\(count)", "bytes": "\(byteCount)", "mode": mode.rawValue])
        switch mode {
        case .sequential: sendNextOfRun()
        case .burst:
            while self.run?.nextSeq ?? (count + 1) <= count { sendNextOfRun() }
        }
    }

    private func sendNextOfRun() {
        guard var run, run.nextSeq <= run.count else { return }
        let seq = run.nextSeq
        run.nextSeq += 1
        self.run = run
        runStore.save(run)
        sendGenerated(runID: run.runID, seq: seq, byteCount: run.byteCount)
    }

    /// Writes `byteCount` random bytes to the outbox and sends them. Random bytes, so no
    /// layer can compress them: a 30-second recording is about 250 KB (docs/architecture.md §8).
    @discardableResult
    func sendGenerated(runID: String, seq: Int, byteCount: Int, id: String = UUID().uuidString) -> String {
        let url = Folders.folder("Outbox").appending(path: "\(id).bin")
        var generator = SystemRandomNumberGenerator()
        var data = Data(count: byteCount)
        data.withUnsafeMutableBytes { buffer in
            for index in stride(from: 0, to: byteCount, by: 8) {
                var value = generator.next()
                withUnsafeBytes(of: &value) { bytes in
                    for offset in 0..<min(8, byteCount - index) { buffer[index + offset] = bytes[offset] }
                }
            }
        }
        try? data.write(to: url)
        let manifest = TransferManifest(
            id: id, attempt: 1, runID: runID, seq: seq, kind: .generated, byteCount: byteCount,
            sha256: SP2.sha256(of: url) ?? "", enqueuedAt: .now, recording: nil)
        send(manifest, file: url)
        return id
    }

    /// Sends a finished recording. The file stays in the outbox until it is acknowledged.
    func sendRecording(_ url: URL, info: RecordingInfo) {
        let id = url.deletingPathExtension().lastPathComponent
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        let manifest = TransferManifest(
            id: id, attempt: 1, runID: "rec", seq: 0, kind: .recording, byteCount: size,
            sha256: SP2.sha256(of: url) ?? "", enqueuedAt: .now, recording: info)
        send(manifest, file: url)
    }

    private func send(_ manifest: TransferManifest, file url: URL) {
        let transfer = WCSession.default.transferFile(
            url, metadata: [SP2.manifestKey: SP2.encode(manifest)])
        var record = WatchTransfer(manifest: manifest, fileName: url.lastPathComponent)
        record.totalUnits = transfer.progress.totalUnitCount
        live[record.id] = transfer
        transfers.append(record)
        save()
        log.append(
            "watch.send",
            [
                "id": manifest.id, "attempt": "\(manifest.attempt)", "run": manifest.runID, "seq": "\(manifest.seq)",
                "bytes": "\(manifest.byteCount)", "kind": manifest.kind.rawValue,
                "transferring": "\(transfer.isTransferring)", "outstanding": "\(WCSession.default.outstandingFileTransfers.count)",
            ])
    }

    /// Sends again every capture that is in the outbox, not acknowledged, and not queued.
    func resendUnacknowledged() {
        let acknowledged = Set(transfers.filter { $0.checksumOK == true }.map(\.manifest.id))
        let queued = Set(live.keys.compactMap { $0.split(separator: "#").first.map(String.init) })
        var latest: [String: WatchTransfer] = [:]
        for record in transfers where !acknowledged.contains(record.manifest.id) {
            if (latest[record.manifest.id]?.manifest.attempt ?? 0) < record.manifest.attempt {
                latest[record.manifest.id] = record
            }
        }
        for (id, record) in latest where !queued.contains(id) {
            let url = Folders.folder("Outbox").appending(path: record.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var manifest = record.manifest
            manifest.attempt += 1
            manifest.enqueuedAt = .now
            send(manifest, file: url)
        }
    }

    func cancelAll() {
        for (key, transfer) in live {
            transfer.cancel()
            if let index = transfers.firstIndex(where: { $0.id == key }) { transfers[index].cancelled = true }
            log.append("watch.cancel", ["key": key])
        }
        save()
    }

    func cancel(id: String) {
        for (key, transfer) in live where key.hasPrefix(id + "#") {
            transfer.cancel()
            if let index = transfers.firstIndex(where: { $0.id == key }) { transfers[index].cancelled = true }
            log.append("watch.cancel", ["key": key, "transferring-after": "\(transfer.isTransferring)"])
        }
        save()
    }

    func clear() {
        cancelAll()
        live = [:]
        transfers = []
        run = nil
        try? FileManager.default.removeItem(at: Folders.folder("Outbox"))
        try? FileManager.default.removeItem(at: runStore.url)
        save()
        log.clear()
    }

    // MARK: Progress and stalls

    private func tick() {
        refreshState()
        let now = Date()
        var changed = false
        for (key, transfer) in live {
            guard let index = transfers.firstIndex(where: { $0.id == key }) else { continue }
            let completed = transfer.progress.completedUnitCount
            transfers[index].totalUnits = transfer.progress.totalUnitCount
            if completed != transfers[index].lastCompleted {
                transfers[index].lastCompleted = completed
                transfers[index].lastProgressAt = now
                if transfers[index].firstProgressAt == nil { transfers[index].firstProgressAt = now }
                if transfers[index].inStall {
                    transfers[index].inStall = false
                    log.append("watch.stall.end", ["key": key])
                }
                changed = true
                continue
            }
            let since = transfers[index].lastProgressAt ?? transfers[index].manifest.enqueuedAt
            if !transfers[index].inStall, now.timeIntervalSince(since) > stallSeconds {
                transfers[index].inStall = true
                transfers[index].stalls += 1
                changed = true
                log.append(
                    "watch.stall",
                    [
                        "key": key, "completed": "\(completed)", "total": "\(transfer.progress.totalUnitCount)",
                        "transferring": "\(transfer.isTransferring)", "reachable": "\(reachable)",
                    ])
                if requeueOnStall {
                    transfer.cancel()
                    live[key] = nil
                    transfers[index].cancelled = true
                    var manifest = transfers[index].manifest
                    manifest.attempt += 1
                    manifest.enqueuedAt = now
                    send(manifest, file: Folders.folder("Outbox").appending(path: transfers[index].fileName))
                }
            }
        }
        if changed { save() }
    }

    private func save() { store.save(transfers) }

    // MARK: Delegate events, on the main actor

    private func finished(_ manifest: TransferManifest, error: String?, order: Int) {
        let key = "\(manifest.id)#\(manifest.attempt)"
        live[key] = nil
        if let index = transfers.firstIndex(where: { $0.id == key }) {
            transfers[index].finishedAt = .now
            transfers[index].finishError = error
        }
        save()
        log.append(
            "watch.finished",
            [
                "id": manifest.id, "attempt": "\(manifest.attempt)", "seq": "\(manifest.seq)", "error": error ?? "",
                "order": "\(order)",
            ])
        report(key)
        if error != nil, run?.mode == .sequential, manifest.runID == run?.runID { sendNextOfRun() }
    }

    private func received(_ message: LinkMessage, order: Int) {
        switch message {
        case .ack(let ack):
            let key = "\(ack.id)#\(ack.attempt)"
            if let index = transfers.firstIndex(where: { $0.id == key }) {
                transfers[index].ackedAt = .now
                transfers[index].checksumOK = ack.checksumOK
            }
            if ack.checksumOK, let name = transfers.first(where: { $0.manifest.id == ack.id })?.fileName {
                try? FileManager.default.removeItem(at: Folders.folder("Outbox").appending(path: name))
            }
            save()
            log.append(
                "watch.ack",
                ["id": ack.id, "attempt": "\(ack.attempt)", "ok": "\(ack.checksumOK)", "order": "\(order)"])
            report(key)
            if let run, run.mode == .sequential,
                transfers.first(where: { $0.id == key })?.manifest.runID == run.runID
            {
                sendNextOfRun()
            }
        case .transcribed(let transcribed):
            lastTranscribed = transcribed
            log.append(
                "watch.transcribed",
                ["id": transcribed.id, "seconds": String(format: "%.2f", transcribed.seconds), "order": "\(order)"])
        case .probe(let probe):
            log.append("watch.probe.received", ["seq": "\(probe.seq)", "order": "\(order)"])
        case .report:
            break
        }
    }

    /// Sends the Watch's timings for one attempt to the phone, so the phone's table is whole.
    private func report(_ key: String) {
        guard let record = transfers.first(where: { $0.id == key }) else { return }
        let report = Report(
            id: record.manifest.id, attempt: record.manifest.attempt, enqueuedAt: record.manifest.enqueuedAt,
            finishedAt: record.finishedAt, finishError: record.finishError, ackedAt: record.ackedAt,
            stalls: record.stalls)
        WCSession.default.transferUserInfo([SP2.messageKey: SP2.encode(LinkMessage.report(report))])
    }

    // MARK: Probes, for the order and duplication tests

    func sendProbes(_ count: Int, paddingBytes: Int = 0) {
        for _ in 0..<count {
            probeSeq += 1
            let probe = Probe(seq: probeSeq, sentAt: .now, padding: String(repeating: "x", count: paddingBytes))
            let transfer = WCSession.default.transferUserInfo([SP2.messageKey: SP2.encode(LinkMessage.probe(probe))])
            log.append("watch.probe.sent", ["seq": "\(probeSeq)", "transferring": "\(transfer.isTransferring)"])
        }
    }

    func sendContexts(_ count: Int) {
        for _ in 0..<count {
            contextSeq += 1
            let payload = ContextPayload(seq: contextSeq, sentAt: .now, joinableCaptureEndedAt: nil, windowMinutes: 5)
            do {
                try WCSession.default.updateApplicationContext([SP2.contextKey: SP2.encode(payload)])
                log.append("watch.context.sent", ["seq": "\(contextSeq)"])
            } catch {
                log.append("watch.context.error", ["seq": "\(contextSeq)", "error": describe(error) ?? ""])
            }
        }
    }

    // MARK: WCSessionDelegate, called on the session's own serial queue

    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let error = describe(error)
        Task { @MainActor in self.activated(activationState, error: error) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.reachable = reachable
            self.log.append("watch.reachability", ["reachable": "\(reachable)"])
        }
    }

    nonisolated func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        let installed = session.isCompanionAppInstalled
        Task { @MainActor in
            self.companionInstalled = installed
            self.log.append("watch.companion-installed", ["installed": "\(installed)"])
        }
    }

    nonisolated func session(
        _ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?
    ) {
        let order = callbackCounter.withLock { value in
            value += 1
            return value
        }
        let error = describe(error)
        let progress = fileTransfer.progress
        EventLog.shared.append(
            "watch.finished.progress",
            [
                "completed": "\(progress.completedUnitCount)", "total": "\(progress.totalUnitCount)",
                "transferring": "\(fileTransfer.isTransferring)", "order": "\(order)",
            ])
        guard
            let manifest = SP2.decode(
                TransferManifest.self, from: fileTransfer.file.metadata, key: SP2.manifestKey)
        else {
            EventLog.shared.append("watch.finished.unknown", ["error": error ?? "", "order": "\(order)"])
            return
        }
        Task { @MainActor in self.finished(manifest, error: error, order: order) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let order = callbackCounter.withLock { value in
            value += 1
            return value
        }
        guard let message = SP2.decode(LinkMessage.self, from: userInfo, key: SP2.messageKey) else {
            EventLog.shared.append("watch.userinfo.unknown", ["order": "\(order)"])
            return
        }
        Task { @MainActor in self.received(message, order: order) }
    }

    nonisolated func session(
        _ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: (any Error)?
    ) {
        if let error = describe(error) {
            EventLog.shared.append("watch.userinfo.failed", ["error": error])
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let context = SP2.decode(ContextPayload.self, from: applicationContext, key: SP2.contextKey) else {
            return
        }
        Task { @MainActor in
            self.lastContext = context
            self.log.append("watch.context.received", ["seq": "\(context.seq)"])
        }
    }
}
