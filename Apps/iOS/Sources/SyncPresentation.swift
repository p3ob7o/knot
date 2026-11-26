import KnotCore
import KnotUI
import SwiftUI

struct SyncPresentation: View {
    let question: SyncQuestion
    let answer: (SyncAnswer) -> Void

    var body: some View {
        Banner(message, symbol: symbol) {
            VStack {
                Button("Keep sync paused") { answer(.keepPaused) }
                Button("Upload local notes") { answer(.upload) }
            }
            .buttonStyle(.borderless)
        }
    }

    private var message: String {
        if case .accountChanged = question { return String(localized: "The iCloud account changed.") }
        return String(localized: "Notes were removed from iCloud.")
    }

    private var symbol: String {
        if case .accountChanged = question { return "person.crop.circle" }
        return "icloud.slash"
    }
}
