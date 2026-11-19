import SwiftUI

/// The spike's instruments on the Watch: start a run, follow it, and see the Watch's own
/// timings. Numbers only.
struct SpikeView: View {
    private var link: WatchLink { .shared }
    private var recorder: WatchRecorder { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("SP-2 transfers").font(.headline)
                Text("\(link.activation) · \(link.reachable ? "reachable" : "not reachable")")
                    .font(.caption2)
                if let run = link.run {
                    Text("Run \(run.runID) · \(run.mode.rawValue) · \(run.count) × \(kilobytes(run.byteCount))")
                        .font(.caption2)
                }
                counts
                Button("30 × 250 KB, one by one") {
                    link.startRun(count: 30, byteCount: 250_000, mode: .sequential)
                }
                Button("30 × 250 KB, all queued") {
                    link.startRun(count: 30, byteCount: 250_000, mode: .burst)
                }
                Button("5 × 15 MB, all queued") {
                    link.startRun(count: 5, byteCount: 15_000_000, mode: .burst)
                }
                Toggle("Re-queue a stalled file", isOn: Binding(get: { link.requeueOnStall }, set: { link.requeueOnStall = $0 }))
                    .font(.caption2)
                Button("Send unacknowledged again") { link.resendUnacknowledged() }
                Button("Cancel all", role: .destructive) { link.cancelAll() }
                Button("Clear", role: .destructive) { link.clear() }
                if let last = recorder.last {
                    Divider()
                    Text("Last recording").font(.headline)
                    Text("\(last.source) · \(seconds(last.duration)) · gap \(milliseconds(last.largestGap))")
                        .font(.caption2)
                    Text("Audio \(seconds(Double(last.frames) / last.sampleRate)), inactive \(seconds(last.inactiveSeconds))")
                        .font(.caption2)
                }
            }
        }
    }

    private var counts: some View {
        let transfers = link.transfers
        let finished = transfers.filter { $0.finishedAt != nil && $0.finishError == nil }
        let acked = transfers.filter { $0.checksumOK == true }
        let failed = transfers.filter { $0.finishError != nil }
        let stalls = transfers.reduce(0) { $0 + $1.stalls }
        let toFinish = Summary(finished.compactMap { $0.finishedAt?.timeIntervalSince($0.manifest.enqueuedAt) })
        let toAck = Summary(acked.compactMap { $0.ackedAt?.timeIntervalSince($0.manifest.enqueuedAt) })
        return VStack(alignment: .leading, spacing: 2) {
            Text("Sent \(transfers.count) · done \(finished.count) · acked \(acked.count)")
            Text("Failed \(failed.count) · stalls \(stalls) · waiting \(link.waitingCount)")
            Text("To done: \(toFinish.text)")
            Text("To ack: \(toAck.text)")
        }
        .font(.caption2.monospacedDigit())
    }

    private func kilobytes(_ bytes: Int) -> String {
        bytes >= 1_000_000 ? "\(bytes / 1_000_000) MB" : "\(bytes / 1000) KB"
    }
}
