import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The widget extension: three controls and the recording's Live Activity. It never records.
@main
struct SP1Widgets: WidgetBundle {
    var body: some Widget {
        SP1ToggleControl()
        SP1PressControl()
        SP1ProbeControl()
        SP1RecordingActivity()
    }
}

/// Reads the recording state from the app group, and logs that it did and from which process.
struct RecordingValueProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        let snapshot = GroupDefaultsRecordingState().read()
        let fresh = snapshot.isFresh(at: .now)
        SP1Log.record(
            "control.value",
            ["phase": snapshot.phase.rawValue, "fresh": String(fresh), "defaults": GroupDefaultsRecordingState.probe()])
        return fresh
    }
}

/// A toggle: the system passes the value the control will take, so the log shows whether it
/// matches what the app knows.
struct SP1ToggleControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.p3ob7o.knot.dev.sp1.toggle", provider: RecordingValueProvider()) { isOn in
            ControlWidgetToggle("SP-1 Toggle", isOn: isOn, action: ToggleRecordingIntent()) { on in
                Label(on ? "Recording" : "Record", systemImage: on ? "stop.circle.fill" : "mic.fill")
            }
        }
        .displayName("SP-1 Toggle")
        .description("Starts or stops a test recording. Pinned to the app process.")
    }
}

/// A button with no value, whose intent is not pinned to a process.
struct SP1PressControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.p3ob7o.knot.dev.sp1.press") {
            ControlWidgetButton(action: PressRecordingIntent()) {
                Label("SP-1 Press", systemImage: "mic.circle")
            }
        }
        .displayName("SP-1 Press")
        .description("Starts or stops a test recording. Not pinned to a process.")
    }
}

/// Records nothing: logs where an unpinned plain intent runs.
struct SP1ProbeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.p3ob7o.knot.dev.sp1.probe") {
            ControlWidgetButton(action: ProbeIntent()) {
                Label("SP-1 Probe", systemImage: "stethoscope")
            }
        }
        .displayName("SP-1 Probe")
        .description("Logs which process runs it. Records nothing.")
    }
}

struct SP1RecordingActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SP1RecordingAttributes.self) { context in
            ActivityView(state: context.state)
                .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    ActivityView(state: context.state)
                }
            } compactLeading: {
                Image(systemName: "mic.fill")
            } compactTrailing: {
                if context.state.phase == .recording {
                    Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                        .frame(maxWidth: 48)
                }
            } minimal: {
                Image(systemName: "mic.fill")
            }
        }
    }
}

private struct ActivityView: View {
    let state: SP1RecordingAttributes.ContentState

    var body: some View {
        HStack {
            switch state.phase {
            case .starting:
                Label("Starting", systemImage: "mic")
            case .recording:
                Label {
                    Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false).monospacedDigit()
                } icon: {
                    Image(systemName: "mic.fill").foregroundStyle(.red)
                }
                Spacer()
                Button(intent: StopRecordingIntent()) {
                    Label("Stop", systemImage: "stop.fill")
                }
            case .saved:
                Label("Saved", systemImage: "checkmark.circle.fill")
            case .failed:
                Label("Could not record: \(state.reason ?? "unknown")", systemImage: "exclamationmark.triangle")
                Spacer()
                // A tap on a Live Activity opens its app, which is the "open Knot" of §4.4.
                Text("Tap to open").font(.caption)
            }
        }
    }
}
