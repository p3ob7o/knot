import SwiftUI
import WidgetKit

/// The Watch widget extension: complications, the Smart Stack widget and the control. It
/// shows no note content (docs/product-spec.md §6).
@main
struct KnotWatchWidgets: WidgetBundle {
    var body: some Widget {
        PlaceholderComplication()
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

/// A complication that shows the mark and opens Knot.
struct PlaceholderComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "knot.placeholder", provider: PlaceholderProvider()) { _ in
            Image("KnotMark")
                .resizable()
                .scaledToFit()
                .accessibilityLabel("Knot")
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Knot")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular])
    }
}
