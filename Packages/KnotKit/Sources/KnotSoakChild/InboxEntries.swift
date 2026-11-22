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
        ///
        /// With `besides`, the launch that is capturing while it looks, only what an earlier launch
        /// provably left counts: an item whose manifest names another launch, its payload and the
        /// temporaries of its files. A file with no such manifest may be one this launch is
        /// writing now, and is left to the next launch's look and to the last one, which count
        /// everything.
        static func list(_ locations: StoreLocations, besides current: LaunchID? = nil) -> InboxEntries? {
            let path = locations.inbox.path
            guard FileManager.default.fileExists(atPath: path) else { return InboxEntries(partials: [], others: 0) }
            guard var names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
            if let current {
                var earlier: Set<CaptureID> = []
                for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
                    let url = locations.inbox.appending(path: name, directoryHint: .notDirectory)
                    guard let data = try? Data(contentsOf: url) else { continue }
                    if let manifest = try? CaptureManifest.decode(data), manifest.launchID != current {
                        earlier.insert(manifest.captureID)
                    } else if (try? CaptureManifest.decode(data)) == nil, let id = capture(ofFile: name) {
                        earlier.insert(id)  // a manifest that does not read is no one's in flight
                    }
                }
                names = names.filter { name in
                    let id = name.hasPrefix(".") ? capture(ofPartial: name) : capture(ofFile: name)
                    return id.map(earlier.contains) ?? true
                }
            }
            return sort(names, locations)
        }

        /// The capture an item's file names: `<capture>.<extension>`.
        static func capture(ofFile name: String) -> CaptureID? {
            name.split(separator: ".", maxSplits: 1).first.flatMap { CaptureID(String($0)) }
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

    /// What the soak finds in `Recording/`: every entry, whatever its name. Once recovery has run,
    /// a recording of an earlier launch leaves none of its files there: its manifest, its working
    /// file, its peaks, a conversion's leftover, or a temporary of one of them. One form alone is
    /// set apart: the temporary of the peaks file's atomic creation (`FileManager.createFile`),
    /// `<capture>.peaks.sb-<8 hex>-<6 characters>`, which a kill can cut before its rename, so that
    /// it never held audio. Nothing clears these yet (`SoakRules.peaksTemporariesAreRed`).
    struct RecordingEntries: Hashable, Sendable {
        /// The temporaries of cut peaks writes, by name: each names a capture ID, no content.
        let peaksTemporaries: Set<String>
        /// How many other entries there are.
        let others: Int

        /// Lists `Recording/`, or `nil` when it cannot be listed. With `besides`, the launch that
        /// is recording while it looks, only what an earlier launch provably left counts: the files
        /// of a capture whose manifest names another launch, or that has no manifest of this launch.
        static func list(_ locations: StoreLocations, besides current: LaunchID? = nil) -> RecordingEntries? {
            let path = locations.recording.path
            guard FileManager.default.fileExists(atPath: path) else {
                return RecordingEntries(peaksTemporaries: [], others: 0)
            }
            guard var names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
            if let current {
                var mine: Set<CaptureID> = []
                for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
                    let url = locations.recording.appending(path: name, directoryHint: .notDirectory)
                    guard let data = try? Data(contentsOf: url), let manifest = try? CaptureManifest.decode(data) else {
                        continue
                    }
                    if manifest.launchID == current { mine.insert(manifest.captureID) }
                }
                let all = names
                names = names.filter { name in
                    let id =
                        name.hasPrefix(".")
                        ? InboxEntries.capture(ofPartial: name) : InboxEntries.capture(ofFile: name)
                    // A temporary with no manifest yet may be this launch's first write.
                    if name.hasPrefix("."), let id, !all.contains("\(id).json") { return false }
                    return id.map { !mine.contains($0) } ?? true
                }
            }
            let temporaries = Set(names.filter { isPeaksTemporary($0, locations) })
            return RecordingEntries(peaksTemporaries: temporaries, others: names.count - temporaries.count)
        }

        /// Whether `name` is the temporary of a peaks file's atomic creation, as Foundation names
        /// one: the peaks file's name, `.sb-`, eight hexadecimal digits, `-`, six letters or digits.
        static func isPeaksTemporary(_ name: String, _ locations: StoreLocations) -> Bool {
            guard let range = name.range(of: ".sb-") else { return false }
            let file = String(name[..<range.lowerBound])
            let rest = name[range.upperBound...].split(separator: "-", omittingEmptySubsequences: false)
            guard rest.count == 2, rest[0].count == 8, rest[0].allSatisfy(\.isHexDigit), rest[1].count == 6,
                rest[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
                let id = InboxEntries.capture(ofFile: file)
            else { return false }
            return locations.recordingPeaks(id).lastPathComponent == file
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

        /// Whether a temporary of a cut peaks write left in `Recording/` turns the soak red. Not
        /// yet: the recorder makes its peaks file atomically, through a temporary that a kill can
        /// leave, and its recovery looks only at working files, manifests and its own partials.
        /// Nothing acknowledged is lost in one. The fix is the recorder's, in WP-12's third pull
        /// request, which turns this to true. Until then each is counted, and more of them than kills that could have
        /// cut them is red (`peaks_temporaries_beyond_kills`).
        static let peaksTemporariesAreRed = false
    }
#endif
