import SwiftUI
import WatchConnectivity

@main
struct SP2WatchApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        EventLog.shared.append(
            "watch.launch",
            ["uptime": String(format: "%.3f", ProcessClock.uptime), "arguments": LaunchArguments.value("test") ?? ""])
        WatchLink.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .onOpenURL { url in Task { await WatchRecorder.shared.handle(url) } }
                .task { await LaunchTests.runIfAsked() }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            EventLog.shared.append("watch.scene", ["phase": "\(phase)"])
            WatchRecorder.shared.setAppActive(phase == .active)
        }
        .backgroundTask(.watchConnectivity) {
            await WatchLink.shared.drainPendingContent()
        }
    }
}

/// Two pages. The first is the record control, which is all the Watch app of Knot shows
/// (docs/product-spec.md §6). The second is the spike's own instruments: the transfer runs
/// and their numbers. It shows no text of any recording, because none reaches the Watch.
struct RootView: View {
    var body: some View {
        TabView {
            RecordView()
            SpikeView()
        }
        .tabViewStyle(.verticalPage)
    }
}

struct RecordView: View {
    private var recorder: WatchRecorder { .shared }
    private var link: WatchLink { .shared }

    var body: some View {
        VStack(spacing: 6) {
            Button {
                Task { await recorder.toggle(source: "button") }
            } label: {
                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.title)
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .tint(recorder.isRecording ? .red : .accentColor)
            .handGestureShortcut(.primaryAction)
            .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Record")

            if recorder.phase == .recording, let start = recorder.firstSampleAt {
                Text(timerInterval: start...Date.distantFuture, countsDown: false)
                    .font(.title3.monospacedDigit())
            } else {
                Text(status).font(.footnote).multilineTextAlignment(.center)
            }
            if let latency = recorder.startLatency {
                Text("Live after \(milliseconds(latency))").font(.caption2)
            }
            Text("Waiting: \(link.waitingCount)").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private var status: String {
        switch recorder.phase {
        case .idle: "Ready"
        case .starting: "Starting…"
        case .recording: "Recording"
        case .stopping: "Saving…"
        case .saved: "Saved"
        case .refused(let reason): reason
        case .failed(let reason): reason
        }
    }
}
