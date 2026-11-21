#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore

    /// What the soak finds in `Inbox/`, sorted by one rule that the child's report after
    /// recovery and the parent's last look share.
    ///
    /// Every entry counts, whatever its name. One form alone is set apart: the temporary that
    /// `DurableFile` writes beside one of an item's files before it renames it into place, which a
    /// kill can cut before the rename, so that it never held an item:
    /// `.<capture>.json.<uuid>.partial`, or the same with a payload's name. Nothing clears these
    /// yet (`SoakRules.inboxPartialsAreRed`).
    struct InboxEntries: Hashable, Sendable {
        /// The temporaries of cut writes, by name: each names a capture ID and a UUID, no text.
        let partials: Set<String>
        /// How many other entries there are: items, and anything else.
        let others: Int

        /// Lists `Inbox/`. A folder that is not there holds nothing; one that cannot be listed
        /// answers `nil`.
        static func list(_ locations: StoreLocations) -> InboxEntries? {
            let path = locations.inbox.path
            guard FileManager.default.fileExists(atPath: path) else { return InboxEntries(partials: [], others: 0) }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
            return sort(names, locations)
        }

        static func sort(_ names: [String], _ locations: StoreLocations) -> InboxEntries {
            let partials = Set(names.filter { isPartial($0, locations) })
            return InboxEntries(partials: partials, others: names.count - partials.count)
        }

        /// Whether `name` is `DurableFile`'s temporary of one of an item's files, exactly as it
        /// names one: a dot, the file's name, a dot, a lower-case UUID, `DurableFile.partialSuffix`.
        static func isPartial(_ name: String, _ locations: StoreLocations) -> Bool {
            guard name.hasPrefix("."), name.hasSuffix(DurableFile.partialSuffix) else { return false }
            let inner = name.dropFirst().dropLast(DurableFile.partialSuffix.count)
            guard let dot = inner.lastIndex(of: ".") else { return false }
            let file = String(inner[..<dot])
            let uuid = String(inner[inner.index(after: dot)...])
            guard UUID(uuidString: uuid) != nil, uuid == uuid.lowercased() else { return false }
            guard let id = file.split(separator: ".", maxSplits: 1).first.flatMap({ CaptureID(String($0)) }) else {
                return false
            }
            let itemFiles =
                [locations.inboxManifest(id)]
                + [SegmentKind.typed, .voice, .ink].map {
                    locations.inboxPayload(id, kind: $0)
                }
            return itemFiles.contains { $0.lastPathComponent == file }
        }

        /// The capture a partial's name names.
        static func capture(ofPartial name: String) -> CaptureID? {
            name.dropFirst().split(separator: ".", maxSplits: 1).first.flatMap { CaptureID(String($0)) }
        }
    }

    /// The soak's rules that wait for a fix elsewhere.
    enum SoakRules {
        /// Whether a temporary of a cut write left in `Inbox/` turns the soak red. Not yet: no part
        /// of KnotCapture clears them, and nothing acknowledged is lost in one. The fix is WP-15's
        /// first pull request (KnotCapture/Ingest/), which turns this to true. Until then each is
        /// counted, and more of them than kills that could have cut them is red
        /// (`inbox_partials_beyond_kills`).
        static let inboxPartialsAreRed = false
    }
#endif
