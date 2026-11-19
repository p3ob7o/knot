import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// The session is activated here, before any view, so that a launch in the background
    /// for a delivery reaches the delegate.
    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        EventLog.shared.append(
            "phone.launch",
            [
                "state": PhoneLink.name(application.applicationState),
                "uptime": String(format: "%.3f", ProcessClock.uptime),
            ])
        PhoneLink.shared.activate()
        return true
    }
}

@main
struct SP2PhoneApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            DeliveriesView()
        }
        .onChange(of: scenePhase) { _, phase in
            EventLog.shared.append("phone.scene", ["phase": "\(phase)"])
        }
    }
}

struct DeliveriesView: View {
    private var link: PhoneLink { .shared }
    @State private var csv: URL?

    var body: some View {
        NavigationStack {
            List {
                Section("Session") {
                    Text("\(link.activation) · paired \(yes(link.paired)) · watch app \(yes(link.watchAppInstalled))")
                    Text("Reachable \(yes(link.reachable))")
                }
                Section("Summary") { summary }
                if !link.grants.isEmpty {
                    Section("Background time granted") {
                        ForEach(link.grants) { grant in
                            Text(
                                "\(grant.appState), up \(seconds(grant.processUptime)): remaining \(seconds(grant.remainingAtStart)), granted \(seconds(grant.granted))"
                            )
                            .font(.caption.monospacedDigit())
                        }
                    }
                }
                Section("Deliveries, newest first") {
                    ForEach(link.deliveries.reversed()) { delivery in
                        DeliveryRow(delivery: delivery)
                    }
                }
            }
            .navigationTitle("SP-2")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear", role: .destructive) { link.clear() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let csv {
                        ShareLink(item: csv) { Label("Share CSV", systemImage: "square.and.arrow.up") }
                    } else {
                        Button("CSV") { csv = CSV.write(link.deliveries, grants: link.grants) }
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Send context to the Watch") { link.sendContext() }
                }
            }
            .onChange(of: link.deliveries.count) { csv = nil }
        }
    }

    @ViewBuilder private var summary: some View {
        let generated = link.deliveries.filter { $0.manifest.kind == .generated && $0.checksumOK }
        let recordings = link.deliveries.filter { $0.manifest.kind == .recording && $0.checksumOK }
        let reports = generated.compactMap(\.report)
        Group {
            Text("Files \(link.deliveries.count) · bad \(link.deliveries.filter { !$0.checksumOK }.count) · duplicates \(link.deliveries.filter(\.duplicate).count) · out of order \(outOfOrder)")
            Text("Watch queue → phone: \(Summary(generated.map { $0.receivedAt.timeIntervalSince($0.manifest.enqueuedAt) }).text)")
            Text("Watch queue → done: \(Summary(reports.compactMap { r in r.finishedAt.map { $0.timeIntervalSince(r.enqueuedAt) } }).text)")
            Text("Watch queue → ack: \(Summary(reports.compactMap { r in r.ackedAt.map { $0.timeIntervalSince(r.enqueuedAt) } }).text)")
            Text("Stalls \(reports.reduce(0) { $0 + $1.stalls })")
            if !recordings.isEmpty {
                Text("Stop → transcript: \(Summary(recordings.compactMap(stopToTranscript)).text)")
            }
        }
        .font(.caption.monospacedDigit())
    }

    /// Files of one run that arrived after a file with a higher sequence number.
    private var outOfOrder: Int {
        var count = 0
        var highest: [String: Int] = [:]
        for delivery in link.deliveries.sorted(by: { $0.deliveryIndex < $1.deliveryIndex }) where delivery.manifest.seq > 0 {
            let run = delivery.manifest.runID
            if delivery.manifest.seq < highest[run, default: 0] { count += 1 }
            highest[run] = max(highest[run, default: 0], delivery.manifest.seq)
        }
        return count
    }

    private func yes(_ value: Bool) -> String { value ? "yes" : "no" }
}

func stopToTranscript(_ delivery: PhoneDelivery) -> Double? {
    guard let stopped = delivery.manifest.recording?.stoppedAt, let finished = delivery.transcription?.finishedAt else {
        return nil
    }
    return finished.timeIntervalSince(stopped)
}

struct DeliveryRow: View {
    let delivery: PhoneDelivery

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.bold())
            Text(
                "#\(delivery.deliveryIndex) · \(delivery.appState) · up \(seconds(delivery.processUptime)) · one-way \(seconds(delivery.receivedAt.timeIntervalSince(delivery.manifest.enqueuedAt)))"
            )
            if let report = delivery.report {
                Text(
                    "done \(seconds(report.finishedAt?.timeIntervalSince(report.enqueuedAt))) · ack \(seconds(report.ackedAt?.timeIntervalSince(report.enqueuedAt))) · stalls \(report.stalls)\(report.finishError.map { " · \($0)" } ?? "")"
                )
            }
            if let recording = delivery.manifest.recording {
                Text(
                    "\(recording.source) · \(seconds(recording.duration)) · live after \(milliseconds(recording.firstSampleAt?.timeIntervalSince(recording.triggeredAt))) · process up \(seconds(recording.processUptimeAtTrigger)) · \(recording.endReason)"
                )
                Text(
                    "audio \(seconds(Double(recording.frames) / max(recording.sampleRate, 1))) · inactive \(seconds(recording.inactiveSeconds)) · audio while inactive \(seconds(Double(recording.framesWhileInactive) / max(recording.sampleRate, 1))) · gap \(milliseconds(recording.largestGap))"
                )
            }
            if let transcription = delivery.transcription {
                Text(
                    "transcribed in \(seconds(transcription.seconds)) from \(transcription.appStateAtStart) · \(transcription.wordCount.map { "\($0) words" } ?? "–")\(transcription.expiredBeforeFinish ? " · time ran out" : "")\(transcription.error.map { " · \($0)" } ?? "") · stop → text \(seconds(stopToTranscript(delivery)))"
                )
            }
        }
        .font(.caption2.monospacedDigit())
    }

    private var title: String {
        let manifest = delivery.manifest
        let kind = manifest.kind == .recording ? "Recording" : "Run \(manifest.runID) #\(manifest.seq)"
        let size = manifest.byteCount >= 1_000_000 ? "\(manifest.byteCount / 1_000_000) MB" : "\(manifest.byteCount / 1000) KB"
        let flags = [
            delivery.checksumOK ? nil : "BAD", delivery.duplicate ? "duplicate" : nil,
            manifest.attempt > 1 ? "attempt \(manifest.attempt)" : nil,
        ].compactMap { $0 }
        return ([kind, size] + flags).joined(separator: " · ")
    }
}

/// The table for the report, numbers only. Times are seconds; "w" marks the Watch's clock.
enum CSV {
    static func write(_ deliveries: [PhoneDelivery], grants: [BackgroundGrant]) -> URL? {
        func number(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "" }
        var lines = [
            [
                "kind", "run", "seq", "id", "attempt", "bytes", "delivery_order", "checksum_ok", "duplicate",
                "app_state", "process_uptime", "background_remaining", "one_way_cross_clock", "w_queue_to_done",
                "w_queue_to_ack", "stalls", "finish_error", "source", "w_trigger_to_first_sample",
                "w_process_uptime_at_trigger", "duration", "audio_seconds", "inactive_seconds",
                "audio_seconds_while_inactive", "largest_gap", "end_reason", "transcribe_seconds",
                "transcribe_app_state", "transcribe_background_remaining", "words", "transcribe_error",
                "transcribe_time_ran_out", "stop_to_transcript_cross_clock",
            ].joined(separator: ",")
        ]
        for delivery in deliveries {
            let manifest = delivery.manifest
            let report = delivery.report
            let recording = manifest.recording
            let rate = max(recording?.sampleRate ?? 1, 1)
            let transcription = delivery.transcription
            lines.append(
                [
                    manifest.kind.rawValue, manifest.runID, "\(manifest.seq)", manifest.id, "\(manifest.attempt)",
                    "\(manifest.byteCount)", "\(delivery.deliveryIndex)", "\(delivery.checksumOK)",
                    "\(delivery.duplicate)", delivery.appState, number(delivery.processUptime),
                    number(delivery.backgroundTimeRemaining),
                    number(delivery.receivedAt.timeIntervalSince(manifest.enqueuedAt)),
                    number(report?.finishedAt?.timeIntervalSince(manifest.enqueuedAt)),
                    number(report?.ackedAt?.timeIntervalSince(manifest.enqueuedAt)), "\(report?.stalls ?? 0)",
                    report?.finishError ?? "", recording?.source ?? "",
                    number(recording?.firstSampleAt?.timeIntervalSince(recording?.triggeredAt ?? .distantPast)),
                    number(recording?.processUptimeAtTrigger), number(recording?.duration),
                    number(recording.map { Double($0.frames) / rate }), number(recording?.inactiveSeconds),
                    number(recording.map { Double($0.framesWhileInactive) / rate }), number(recording?.largestGap),
                    recording?.endReason ?? "", number(transcription?.seconds), transcription?.appStateAtStart ?? "",
                    number(transcription?.backgroundTimeRemainingAtStart),
                    transcription?.wordCount.map(String.init) ?? "", transcription?.error ?? "",
                    "\(transcription?.expiredBeforeFinish ?? false)", number(stopToTranscript(delivery)),
                ].joined(separator: ","))
        }
        lines.append("")
        lines.append("grant_trigger,app_state,process_uptime,remaining_at_start,granted")
        for grant in grants {
            lines.append(
                [
                    grant.trigger, grant.appState, number(grant.processUptime), number(grant.remainingAtStart),
                    number(grant.granted),
                ].joined(separator: ","))
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "sp2-deliveries.csv")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
