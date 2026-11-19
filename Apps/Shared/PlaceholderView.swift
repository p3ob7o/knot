import SwiftUI

/// What each app shows until its own package builds the real surface: the mark.
struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image("KnotMark")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 96, maxHeight: 96)
                .accessibilityLabel("Knot")
                .accessibilityIdentifier("knot.mark")
            Text("Knot")
                .font(.headline)
        }
        .padding()
    }
}
