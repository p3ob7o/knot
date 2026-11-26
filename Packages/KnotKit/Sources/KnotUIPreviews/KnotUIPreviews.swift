#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore
    import KnotFakes
    import KnotUI

    /// SwiftUI previews of KnotUI, on the preview environment (docs/architecture.md §16).
    ///
    /// The named previews follow the state matrix in docs/design/brief.md §6. Like KnotFakes,
    /// this module is compiled only under DEBUG or KNOT_FAKES.
    public enum KnotUIPreviews {
        /// The environment every preview runs on.
        public static var environment: AppEnvironment {
            .preview
        }

        /// What the view models know of the preview's device: the preview store's own, and a
        /// build that cannot sync, as an agent's local configuration.
        public static func context(for environment: AppEnvironment = .preview) -> UIContext {
            let device = (environment.notes as? InMemoryNoteStore)?.deviceID ?? environment.ids.make()
            return UIContext(thisDevice: device, sync: .notInThisBuild)
        }

        /// Fills a preview environment with a few synthetic notes, through its engine, as a person
        /// typing would. On the Watch, which has no engine, it does nothing.
        public static func seed(_ environment: AppEnvironment) async {
            let engine = environment.engine
            let lines: [(String, CapturePlacement)] = [
                ("Call the roofer about the leak\nAsk for Thursday", .newNote),
                ("Buy stamps", .newNote),
                ("and envelopes", .window),
            ]
            for (text, placement) in lines {
                let request = CaptureRequest(kind: .typed, surface: .app, placement: placement, text: text)
                guard let state = try? await engine.begin(request) else { return }
                _ = try? await engine.end(state.captureID)
            }
        }
    }
#endif
