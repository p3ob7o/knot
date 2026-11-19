import Foundation
import Observation
import UIKit
import WatchConnectivity
import os

/// One file as the phone received it.
struct PhoneDelivery: Codable, Sendable, Identifiable {
    var id: Int { deliveryIndex }
    var manifest: TransferManifest
    /// The order of `didReceive file` callbacks in this process, counted on the delegate queue.
    var deliveryIndex: Int
    var receivedAt: Date
    var moved: Bool
    var checksumOK: Bool
    var duplicate: Bool = false
    var appState: String = ""
    var backgroundTimeRemaining: Double?
    var processUptime: Double = 0
    var storedName: String
    var report: Report?
    var transcription: TranscriptionRecord?
}

struct TranscriptionRecord: Codable, Sendable {
    var startedAt: Date
    var appStateAtStart: String
    var backgroundTimeRemainingAtStart: Double?
    var finishedAt: Date?
    var seconds: Double?
    var wordCount: Int?
    var error: String?
    var expiredBeforeFinish: Bool = false
}

/// One background task held from a delivery until the system ends it: how much time the
/// phone grants when the app is not in front.
struct BackgroundGrant: Codable, Sendable, Identifiable {
    var id: Date { startedAt }
    var trigger: String
    var startedAt: Date
    var appState: String
    var processUptime: Double
    var remainingAtStart: Double?
    var expiredAt: Date?
    var granted: Double?
}

/// The phone's side of `WCSession`: takes each file before the delegate call returns,
/// checks it against its manifest, acknowledges it, and times everything.
@MainActor @Observable
final class PhoneLink: NSObject, WCSessionDelegate {
    static let shared = PhoneLink()

    private(set) var activation = "not activated"
    private(set) var paired = false
    private(set) var watchAppInstalled = false
    private(set) var reachable = false
    private(set) var deliveries: [PhoneDelivery] = []
    private(set) var grants: [BackgroundGrant] = []
    private(set) var probes: [Int] = []
    private(set) var contexts: [Int] = []

    @ObservationIgnored private let store = JSONFile<[PhoneDelivery]>("phone-deliveries.json")
    @ObservationIgnored private let grantStore = JSONFile<[BackgroundGrant]>("phone-grants.json")
    @ObservationIgnored private var grantTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var contextSeq = 0
    nonisolated private let callbackCounter = OSAllocatedUnfairLock(initialState: 0)
    private let log = EventLog.shared

    override private init() {
        super.init()
        deliveries = store.load() ?? []
        grants = grantStore.load() ?? []
    }

    func activate() {
        guard WCSession.isSupported() else {
            activation = "not supported"
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private func refreshState() {
        let session = WCSession.default
        activation =
            switch session.activationState {
            case .activated: "activated"
            case .inactive: "inactive"
            case .notActivated: "not activated"
            @unknown default: "unknown"
            }
        paired = session.isPaired
        watchAppInstalled = session.isWatchAppInstalled
        reachable = session.isReachable
    }

    static func name(_ state: UIApplication.State) -> String {
        switch state {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }

    // MARK: Receiving, on the main actor

    private func received(_ delivery: PhoneDelivery) {
        var delivery = delivery
        let application = UIApplication.shared
        delivery.appState = Self.name(application.applicationState)
        let remaining = application.backgroundTimeRemaining
        delivery.backgroundTimeRemaining = remaining < 1_000_000 ? remaining : nil
        delivery.processUptime = ProcessClock.uptime
        delivery.duplicate = deliveries.contains { $0.manifest.id == delivery.manifest.id && $0.checksumOK }
        deliveries.append(delivery)
        store.save(deliveries)
        log.append(
            "phone.received",
            [
                "id": delivery.manifest.id, "attempt": "\(delivery.manifest.attempt)", "run": delivery.manifest.runID,
                "seq": "\(delivery.manifest.seq)", "order": "\(delivery.deliveryIndex)",
                "ok": "\(delivery.checksumOK)", "duplicate": "\(delivery.duplicate)", "state": delivery.appState,
                "uptime": String(format: "%.3f", delivery.processUptime),
                "one-way": String(format: "%.3f", delivery.receivedAt.timeIntervalSince(delivery.manifest.enqueuedAt)),
            ])
        if application.applicationState != .active { holdBackgroundGrant(trigger: delivery.manifest.id) }
        if delivery.manifest.kind == .recording, delivery.checksumOK {
            transcribe(delivery)
        }
    }

    /// Holds one background task until the system expires it, and records how long that was.
    private func holdBackgroundGrant(trigger: String) {
        guard grantTask == .invalid else { return }
        let application = UIApplication.shared
        let remaining = application.backgroundTimeRemaining
        let grant = BackgroundGrant(
            trigger: trigger, startedAt: .now, appState: Self.name(application.applicationState),
            processUptime: ProcessClock.uptime, remainingAtStart: remaining < 1_000_000 ? remaining : nil)
        grants.append(grant)
        grantStore.save(grants)
        grantTask = application.beginBackgroundTask(withName: "sp2.grant") {
            PhoneLink.shared.grantExpired()
        }
        log.append(
            "phone.grant.start", ["trigger": trigger, "remaining": String(format: "%.1f", remaining)])
    }

    private func grantExpired() {
        if let index = grants.indices.last {
            grants[index].expiredAt = .now
            grants[index].granted = Date().timeIntervalSince(grants[index].startedAt)
            grantStore.save(grants)
            log.append(
                "phone.grant.expired",
                ["trigger": grants[index].trigger, "granted": String(format: "%.1f", grants[index].granted ?? -1)])
        }
        UIApplication.shared.endBackgroundTask(grantTask)
        grantTask = .invalid
    }

    private func transcribe(_ delivery: PhoneDelivery) {
        let application = UIApplication.shared
        let remaining = application.backgroundTimeRemaining
        let record = TranscriptionRecord(
            startedAt: .now, appStateAtStart: Self.name(application.applicationState),
            backgroundTimeRemainingAtStart: remaining < 1_000_000 ? remaining : nil)
        update(delivery.deliveryIndex) { $0.transcription = record }
        let index = delivery.deliveryIndex
        let task = application.beginBackgroundTask(withName: "sp2.transcribe") {
            PhoneLink.shared.update(index) { $0.transcription?.expiredBeforeFinish = true }
            PhoneLink.shared.log.append("phone.transcribe.expired", ["id": delivery.manifest.id])
        }
        let url = Folders.folder("Inbox").appending(path: delivery.storedName)
        log.append("phone.transcribe.start", ["id": delivery.manifest.id, "state": record.appStateAtStart])
        Task {
            let started = Date()
            let outcome = await Transcription.run(url)
            let finished = Date()
            update(index) {
                $0.transcription?.finishedAt = finished
                $0.transcription?.seconds = finished.timeIntervalSince(started)
                $0.transcription?.wordCount = outcome.wordCount
                $0.transcription?.error = outcome.error
            }
            log.append(
                "phone.transcribe.end",
                [
                    "id": delivery.manifest.id, "seconds": String(format: "%.2f", finished.timeIntervalSince(started)),
                    "words": "\(outcome.wordCount)", "error": outcome.error ?? "",
                    "state": Self.name(UIApplication.shared.applicationState),
                ])
            let message = LinkMessage.transcribed(
                Transcribed(
                    id: delivery.manifest.id, finishedAt: finished, seconds: finished.timeIntervalSince(started),
                    wordCount: outcome.wordCount, error: outcome.error))
            WCSession.default.transferUserInfo([SP2.messageKey: SP2.encode(message)])
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    private func update(_ index: Int, _ change: (inout PhoneDelivery) -> Void) {
        guard let position = deliveries.firstIndex(where: { $0.deliveryIndex == index }) else { return }
        change(&deliveries[position])
        store.save(deliveries)
    }

    private func receivedMessage(_ message: LinkMessage, order: Int) {
        switch message {
        case .report(let report):
            for position in deliveries.indices
            where deliveries[position].manifest.id == report.id && deliveries[position].manifest.attempt == report.attempt {
                deliveries[position].report = report
            }
            store.save(deliveries)
            log.append(
                "phone.report",
                ["id": report.id, "attempt": "\(report.attempt)", "acked": "\(report.ackedAt != nil)", "order": "\(order)"])
        case .probe(let probe):
            probes.append(probe.seq)
            log.append("phone.probe.received", ["seq": "\(probe.seq)", "order": "\(order)"])
        case .ack, .transcribed:
            break
        }
    }

    // MARK: Actions

    func sendContext(count: Int = 1) {
        for _ in 0..<count {
            contextSeq += 1
            let payload = ContextPayload(
                seq: contextSeq, sentAt: .now, joinableCaptureEndedAt: Date().addingTimeInterval(-60), windowMinutes: 5)
            do {
                try WCSession.default.updateApplicationContext([SP2.contextKey: SP2.encode(payload)])
                log.append("phone.context.sent", ["seq": "\(contextSeq)"])
            } catch {
                log.append("phone.context.error", ["error": describe(error) ?? ""])
            }
        }
    }

    func clear() {
        deliveries = []
        grants = []
        probes = []
        contexts = []
        store.save([])
        grantStore.save([])
        try? FileManager.default.removeItem(at: Folders.folder("Inbox"))
        log.clear()
    }

    /// Ten numbered user-info payloads to the Watch: the direction of every acknowledgement.
    nonisolated static func sendProbes(_ count: Int) {
        for seq in 1...count {
            let probe = Probe(seq: seq, sentAt: .now, padding: "")
            WCSession.default.transferUserInfo([SP2.messageKey: SP2.encode(LinkMessage.probe(probe))])
            EventLog.shared.append("phone.probe.sent", ["seq": "\(seq)"])
        }
    }

    // MARK: WCSessionDelegate, called on the session's own serial queue

    nonisolated func session(
        _ session: WCSession, didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        EventLog.shared.append("phone.message.received", ["seq": "\(message["seq"] as? Int ?? -1)"])
        replyHandler(["ok": true])
    }

    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let error = describe(error)
        let pending = session.hasContentPending
        Task { @MainActor in
            self.refreshState()
            self.log.append(
                "phone.activation",
                [
                    "state": self.activation, "error": error ?? "", "paired": "\(self.paired)",
                    "installed": "\(self.watchAppInstalled)", "pending": "\(pending)",
                    "app-state": Self.name(UIApplication.shared.applicationState),
                ])
            switch LaunchArguments.value("test") {
            case "context": self.sendContext(count: 5)
            case "probes": Self.sendProbes(10)
            default: break
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        EventLog.shared.append("phone.session.inactive")
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        EventLog.shared.append("phone.session.deactivated")
        // Apple's rule for a change of watch: activate again for the new one.
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        Task { @MainActor in
            self.paired = paired
            self.watchAppInstalled = installed
            self.log.append("phone.watch-state", ["paired": "\(paired)", "installed": "\(installed)"])
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.reachable = reachable
            self.log.append("phone.reachability", ["reachable": "\(reachable)"])
        }
    }

    /// The system deletes the file when this returns, so the move happens here, on the
    /// delegate's queue (docs/architecture.md §12). The acknowledgement goes as soon as the
    /// file is durably in place and matches its manifest.
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let receivedAt = Date()
        let order = callbackCounter.withLock { value in
            value += 1
            return value
        }
        guard let manifest = SP2.decode(TransferManifest.self, from: file.metadata, key: SP2.manifestKey) else {
            EventLog.shared.append("phone.received.unknown", ["order": "\(order)"])
            return
        }
        let ext = manifest.kind == .recording ? "m4a" : "bin"
        let name = "\(manifest.id)-\(manifest.attempt)-\(order).\(ext)"
        let destination = Folders.folder("Inbox").appending(path: name)
        var moved = true
        do {
            try FileManager.default.moveItem(at: file.fileURL, to: destination)
            if let handle = try? FileHandle(forUpdating: destination) {
                try? handle.synchronize()
                try? handle.close()
            }
        } catch {
            moved = false
            EventLog.shared.append("phone.move.failed", ["id": manifest.id, "error": describe(error) ?? ""])
        }
        let checksumOK = moved && SP2.sha256(of: destination) == manifest.sha256
        if checksumOK {
            let ack = Ack(id: manifest.id, attempt: manifest.attempt, receivedAt: receivedAt, checksumOK: true)
            session.transferUserInfo([SP2.messageKey: SP2.encode(LinkMessage.ack(ack))])
        }
        let delivery = PhoneDelivery(
            manifest: manifest, deliveryIndex: order, receivedAt: receivedAt, moved: moved,
            checksumOK: checksumOK, storedName: name)
        Task { @MainActor in self.received(delivery) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let order = callbackCounter.withLock { value in
            value += 1
            return value
        }
        guard let message = SP2.decode(LinkMessage.self, from: userInfo, key: SP2.messageKey) else {
            EventLog.shared.append("phone.userinfo.unknown", ["order": "\(order)"])
            return
        }
        Task { @MainActor in self.receivedMessage(message, order: order) }
    }

    nonisolated func session(
        _ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: (any Error)?
    ) {
        if let error = describe(error) {
            EventLog.shared.append("phone.userinfo.failed", ["error": error])
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let context = SP2.decode(ContextPayload.self, from: applicationContext, key: SP2.contextKey) else {
            return
        }
        Task { @MainActor in
            self.contexts.append(context.seq)
            self.log.append("phone.context.received", ["seq": "\(context.seq)"])
        }
    }
}
