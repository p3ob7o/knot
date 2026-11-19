import AppIntents
import SwiftUI
import WidgetKit

/// In the widget extension an intent cannot record: the recorder lives in the app. If the
/// system runs a control's intent here, the extension's event log says so, and nothing
/// records. That is one of the answers SP-2 looks for.
enum RecordIntentBridge {
    static func start(source: String, intent: String) async {
        EventLog.shared.append(
            "intent.perform",
            ["process": "widget-extension", "intent": intent, "source": source])
    }
}

@main
struct SP2WatchWidgets: WidgetBundle {
    var body: some Widget {
        RecordComplication()
        RecordSmartStackWidget()
        RecordControl()
        RecordInBackgroundControl()
    }
}

struct StaticEntry: TimelineEntry {
    let date: Date
}

struct StaticProvider: TimelineProvider {
    func placeholder(in context: Context) -> StaticEntry { StaticEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (StaticEntry) -> Void) {
        completion(StaticEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<StaticEntry>) -> Void) {
        completion(Timeline(entries: [StaticEntry(date: .now)], policy: .never))
    }
}

/// The complication. A tap opens the app with a URL, and the app starts recording: the time
/// from the tap to the first sample is the brief's "complication tap" latency.
struct RecordComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "sp2.complication", provider: StaticProvider()) { _ in
            Image(systemName: "mic.fill")
                .font(.title3)
                .widgetAccentable()
                .accessibilityLabel("Record")
                .widgetURL(URL(string: "sp2://record?source=complication"))
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("SP-2 record")
        .description("Opens the SP-2 spike already recording.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

/// The Smart Stack widget. Its button runs the foreground intent, and Double Tap presses it,
/// which is how "Double Tap when Knot is not the app in front" is tried.
struct RecordSmartStackWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "sp2.smartstack", provider: StaticProvider()) { _ in
            HStack {
                Text("SP-2")
                Spacer()
                Button(intent: RecordIntent(source: "smart-stack")) {
                    Label("Record", systemImage: "mic.fill")
                }
                .handGestureShortcut(.primaryAction)
            }
            .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("SP-2 record button")
        .description("Records with a tap or with Double Tap.")
        .supportedFamilies([.accessoryRectangular])
    }
}

/// The control, for Control Center and the Ultra's Action Button. It runs the intent that
/// brings the app forward.
struct RecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "sp2.control.record") {
            ControlWidgetButton(action: RecordIntent(source: "control")) {
                Label("SP-2 record", systemImage: "mic.fill")
            }
        }
        .displayName("SP-2 record")
        .description("Opens the SP-2 spike already recording.")
    }
}

/// The same control with the background intent, to see whether a control can start a
/// recording without bringing the app forward.
struct RecordInBackgroundControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "sp2.control.record-background") {
            ControlWidgetButton(action: RecordInBackgroundIntent(source: "control-background")) {
                Label("SP-2 quiet", systemImage: "mic.badge.plus")
            }
        }
        .displayName("SP-2 record, background")
        .description("Asks the SP-2 spike to record without opening it.")
    }
}
