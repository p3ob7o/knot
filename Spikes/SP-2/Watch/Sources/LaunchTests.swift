import Foundation
import WatchConnectivity

/// What the simulator tests ask for with `-sp2-test <name>`, so that an agent can drive the
/// Watch app with `simctl launch` and no taps. None of them opens the microphone. The
/// results are in the event log of each app.
@MainActor
enum LaunchTests {
    static func runIfAsked() async {
        guard let test = LaunchArguments.value("test") else { return }
        let link = WatchLink.shared
        await link.waitUntilActivated()
        let log = EventLog.shared
        log.append("test.start", ["test": test])
        switch test {
        case "run":
            // -sp2-count, -sp2-bytes, -sp2-mode sequential|burst, -sp2-stall seconds
            if let stall = LaunchArguments.int("stall") { link.stallSeconds = Double(stall) }
            link.requeueOnStall = LaunchArguments.value("requeue") == "yes"
            link.startRun(
                count: LaunchArguments.int("count") ?? 30, byteCount: LaunchArguments.int("bytes") ?? 250_000,
                mode: TransferRun.Mode(rawValue: LaunchArguments.value("mode") ?? "") ?? .sequential)
        case "cancel":
            // Six files queued at once; the second and the fourth cancelled at once, the sixth
            // after a second.
            var ids: [String] = []
            for seq in 1...6 { ids.append(link.sendGenerated(runID: "cancel", seq: seq, byteCount: 250_000)) }
            link.cancel(id: ids[1])
            link.cancel(id: ids[3])
            try? await Task.sleep(for: .seconds(1))
            link.cancel(id: ids[5])
        case "missing":
            // A file that does not exist.
            let url = Folders.folder("Outbox").appending(path: "missing.bin")
            let manifest = TransferManifest(
                id: "missing", attempt: 1, runID: "missing", seq: 1, kind: .generated, byteCount: 0, sha256: "",
                enqueuedAt: .now, recording: nil)
            let transfer = WCSession.default.transferFile(url, metadata: [SP2.manifestKey: SP2.encode(manifest)])
            log.append("test.missing.queued", ["transferring": "\(transfer.isTransferring)"])
        case "duplicate":
            // The same capture sent twice, as a re-send after a lost acknowledgement would.
            let id = link.sendGenerated(runID: "dup", seq: 1, byteCount: 100_000)
            link.resendUnacknowledged()
            log.append("test.duplicate.sent", ["id": id])
        case "probes":
            // Twenty user-info probes in a row, then twenty files of growing size, for order.
            link.sendProbes(20)
            for seq in 1...20 { link.sendGenerated(runID: "order", seq: seq, byteCount: 20_000 * (21 - seq)) }
        case "bigprobe":
            // A user-info payload far above any plausible limit.
            link.sendProbes(1, paddingBytes: 2_000_000)
        case "context":
            link.sendContexts(5)
        case "message":
            // Interactive messaging, which needs the phone reachable. Wait up to 5 seconds.
            for _ in 0..<20 where !WCSession.default.isReachable { try? await Task.sleep(for: .milliseconds(250)) }
            Messaging.send(count: 3)
        case "outstanding":
            // Queue ten files and report what the session holds. The test then terminates the
            // app and launches it again.
            for seq in 1...10 { link.sendGenerated(runID: "relaunch", seq: seq, byteCount: 1_000_000) }
            log.append("test.outstanding", ["count": "\(WCSession.default.outstandingFileTransfers.count)"])
        default:
            log.append("test.unknown", ["test": test])
        }
    }
}

/// `sendMessage` with its handlers made outside any actor, because the session calls them on
/// its own queue.
enum Messaging {
    nonisolated static func send(count: Int) {
        for seq in 1...count {
            let sent = Date()
            WCSession.default.sendMessage(
                ["seq": seq],
                replyHandler: { _ in
                    EventLog.shared.append(
                        "watch.message.reply",
                        ["seq": "\(seq)", "after": String(format: "%.3f", Date().timeIntervalSince(sent))])
                },
                errorHandler: { error in
                    EventLog.shared.append("watch.message.error", ["seq": "\(seq)", "error": describe(error) ?? ""])
                })
            EventLog.shared.append("watch.message.sent", ["seq": "\(seq)", "reachable": "\(WCSession.default.isReachable)"])
        }
    }
}
