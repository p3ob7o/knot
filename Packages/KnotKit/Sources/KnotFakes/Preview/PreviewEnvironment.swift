#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore
    #if os(iOS) || os(macOS)
        import KnotCapture
    #endif

    extension AppEnvironment {
        /// The environment of previews, UI tests and debug builds: on iOS and macOS, the real
        /// capture engine and processing queue running over the fakes (docs/architecture.md §3).
        /// One per process, in a folder of its own under the temporary folder.
        public static let preview: AppEnvironment = makePreview(
            root: FileManager.default.temporaryDirectory.appending(
                path: "KnotPreview-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory))

        /// A preview environment whose files sit under `root`.
        ///
        /// The store is the in-memory one. Files are real, through `PosixFileLayer`: the
        /// scripted recorder's working files, the stored assets and `Inbox/`. The scripted
        /// transcriber reads every file nobody scripted as its default script, so that a
        /// recording made in a preview gets a transcript, and the scripted cleaner takes the
        /// transcript as it is. The queue drains on its own, straight through, as the app's
        /// foreground does.
        public static func makePreview(root: URL) -> AppEnvironment {
            let clock = SystemWallClock()
            let ids = SystemIDGenerator(clock: clock)
            let deviceID: DeviceID = ids.make()
            // The folder the store's root sits in, as an app's container is there before it.
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let locations = StoreLocations.testing(root: root)
            let layer = PosixFileLayer()
            let notes = InMemoryNoteStore(clock: clock, ids: ids, deviceID: deviceID, inbox: locations.inbox)
            let assets = FileAssetStore(locations: locations, layer: layer)
            let recorder = ScriptedRecorder(locations: locations, layer: layer, clock: clock)
            let transcriber = ScriptedTranscriber()
            transcriber.scriptUnscriptedFiles(pieces: ScriptedTranscriber.defaultScript)
            let cleaner = ScriptedCleaner()
            #if os(iOS) || os(macOS)
                let launchID: LaunchID = ids.make()
                let queue = StandardProcessingQueue(
                    notes: notes, assets: assets, transcriber: transcriber, cleaner: cleaner, clock: clock, ids: ids,
                    autoDrain: StraightThroughRunner())
                let ingest = InboxIngest(
                    notes: notes, assets: assets, recorder: recorder, queue: queue, clock: clock, launchID: launchID,
                    locations: locations, layer: layer)
                let engine = StandardCaptureEngine(
                    notes: notes, assets: assets, recorder: recorder, queue: queue, clock: clock, ids: ids,
                    deviceID: deviceID, launchID: launchID, locations: locations, layer: layer, ingest: ingest)
                return AppEnvironment(
                    notes: notes, assets: assets, recorder: recorder, transcriber: transcriber, cleaner: cleaner,
                    clock: clock, ids: ids, engine: engine, queue: queue)
            #else
                // The Watch composes no engine (docs/architecture.md §3).
                return AppEnvironment(
                    notes: notes, assets: assets, recorder: recorder, transcriber: transcriber, cleaner: cleaner,
                    clock: clock, ids: ids, engine: UnavailableCaptureEngine(), queue: UnavailableProcessingQueue())
            #endif
        }
    }
#endif
