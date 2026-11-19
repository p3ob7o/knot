import KnotIntents
import SwiftUI
import WidgetKit

/// The iPhone and iPad widget extension: controls, widgets and the Live Activity views.
/// It never opens the database, and no intent runs here (docs/architecture.md §13–14).
@main
struct KnotWidgets: WidgetBundle {
    var body: some Widget {
        PlaceholderWidget()
        PlaceholderActivityWidget()
    }
}

struct PlaceholderEntry: TimelineEntry {
    let date: Date
}

struct PlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaceholderEntry {
        PlaceholderEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (PlaceholderEntry) -> Void) {
        completion(PlaceholderEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<PlaceholderEntry>) -> Void) {
        completion(Timeline(entries: [PlaceholderEntry(date: .now)], policy: .never))
    }
}

/// A launcher that shows the mark. Widgets never show note text.
struct PlaceholderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "knot.placeholder", provider: PlaceholderProvider()) { _ in
            MarkView()
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Knot")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

/// WP-01's packaging proof for the Live Activity: a configuration for the attributes type
/// that KnotIntents declares. WP-19 replaces it.
struct PlaceholderActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: KnotPlaceholderActivityAttributes.self) { _ in
            MarkView()
        } dynamicIsland: { _ in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    MarkView()
                }
            } compactLeading: {
                Image("KnotMark")
            } compactTrailing: {
                EmptyView()
            } minimal: {
                Image("KnotMark")
            }
        }
    }
}

struct MarkView: View {
    var body: some View {
        Image("KnotMark")
            .resizable()
            .scaledToFit()
            .padding(8)
            .accessibilityLabel("Knot")
    }
}
