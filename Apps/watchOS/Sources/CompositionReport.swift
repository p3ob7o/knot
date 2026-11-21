#if DEBUG
    import Foundation
    import KnotCore
    import KnotLink

    /// What a composition wired, in words a UI test reads: the recorder's type, the link's type
    /// and its transport's, how many items the outbox holds, and whether the store's root is
    /// under the system's temporary folder. Types, a number and a yes or no: nothing of a
    /// recording. Debug builds only, for the smoke test on the real composition.
    struct CompositionReport: Sendable {
        let recorder: String
        let link: String
        let transport: String
        let outbox: WatchOutbox?

        init(_ environment: AppEnvironment) {
            recorder = String(describing: type(of: environment.recorder))
            link = String(describing: type(of: environment.watchLink))
            if let outboxLink = environment.watchLink as? OutboxLink {
                transport = String(describing: type(of: outboxLink.transport))
                outbox = outboxLink.outbox
            } else {
                transport = "none"
                outbox = nil
            }
        }

        /// The report as it stands now: the outbox is read again each time.
        var text: String {
            let items = outbox.map { outbox in (try? outbox.entries().count).map(String.init) ?? "unreadable" }
            let temporary = outbox.map { Self.isTemporary($0.locations.storeRoot) ? "yes" : "no" }
            return "\(recorder); \(link) over \(transport); outbox \(items ?? "none"); "
                + "temporary store \(temporary ?? "unknown")"
        }

        /// Whether `root` is under the system's temporary folder, however either is written:
        /// `/private/var/…` and `/var/…` name the same folder.
        static func isTemporary(_ root: URL) -> Bool {
            let temporary = realPath(FileManager.default.temporaryDirectory)
            let path = realPath(root)
            return path.hasPrefix(temporary.hasSuffix("/") ? temporary : temporary + "/")
        }

        private static func realPath(_ url: URL) -> String {
            var path = url.standardizedFileURL.resolvingSymlinksInPath().path
            if path.hasPrefix("/private/") { path.removeFirst("/private".count) }
            return path
        }
    }
#endif
