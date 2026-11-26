import KnotCore
import SwiftUI

struct SyncPresentation: ViewModifier {
    let shell: Shell
    let isFront: Bool

    func body(content: Content) -> some View {
        let question = shell.syncQuestion
        content.alert(
            question?.title ?? "iCloud sync",
            isPresented: Binding(
                get: { isFront && shell.showsSyncQuestion },
                set: { _ in }),
            presenting: question
        ) { question in
            Button("Keep sync paused", role: .cancel) { shell.answer(question, .keepPaused) }
            Button("Upload local notes") { shell.answer(question, .upload) }
        } message: { _ in
            Text("Your notes stay on this device. Choose whether to upload them to iCloud.")
        }
    }
}

extension SyncQuestion {
    fileprivate var title: LocalizedStringKey {
        switch self {
        case .accountChanged: "Your iCloud account changed"
        case .zoneRemoved: "Notes were removed from iCloud"
        case .signedOut: "You signed out of iCloud"
        case .largeDelete: "Many notes were removed from iCloud"
        case .restoredStore: "Knot restored a kept copy"
        case .environmentChanged: "The iCloud environment changed"
        case .recordTooLarge: "Some notes are too large for iCloud"
        }
    }
}
