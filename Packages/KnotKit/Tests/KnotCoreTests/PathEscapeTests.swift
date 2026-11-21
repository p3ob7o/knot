import Foundation
import Testing

@testable import KnotCore

/// Nothing a store's files do gets out of its root, whatever links lie below it: what is
/// placed, moved or removed lands in the root or is refused. On the real file system, under
/// the temporary folder, each case on a fresh tree.
@Suite(.serialized) struct PathEscapeTests {
    /// scratch/
    ///   KnotStore/            the root, a real folder
    ///   KnotStore/A/          a real folder
    ///   KnotStore/Leak     -> scratch/outside
    ///   KnotStore/A/Last   -> scratch/outside
    ///   KnotStore/Self     -> scratch/KnotStore
    ///   outside/              with a file v1 and a partial .p.partial
    ///   v2, .q.partial        beside the root
    ///   src/s.bin             a file to move
    struct Tree {
        let scratch: URL
        var root: URL { scratch.appending(path: "KnotStore", directoryHint: .isDirectory) }
        var outside: URL { scratch.appending(path: "outside", directoryHint: .isDirectory) }
        var source: URL { scratch.appending(path: "src/s.bin", directoryHint: .notDirectory) }
        func path(_ text: String) -> URL { URL(fileURLWithPath: scratch.path + "/" + text) }

        init() throws {
            let base = FileManager.default.temporaryDirectory.appending(
                path: "path-escape-\(UUID().uuidString)", directoryHint: .isDirectory)
            let fm = FileManager.default
            try fm.createDirectory(at: base.appending(path: "KnotStore/A"), withIntermediateDirectories: true)
            try fm.createDirectory(at: base.appending(path: "outside"), withIntermediateDirectories: true)
            try fm.createDirectory(at: base.appending(path: "src"), withIntermediateDirectories: true)
            scratch = PathForm.folder(PathForm.real(base))
            try fm.createSymbolicLink(at: root.appending(path: "Leak"), withDestinationURL: outside)
            try fm.createSymbolicLink(at: root.appending(path: "A/Last"), withDestinationURL: outside)
            try fm.createSymbolicLink(at: root.appending(path: "Self"), withDestinationURL: root)
            for file in ["outside/v1", "outside/.p.partial", "v2", ".q.partial", "src/s.bin"] {
                try Data("keep".utf8).write(to: path(file))
            }
        }

        /// Every entry outside the root, by its path below `scratch`, never following a link.
        func outsideTheRoot() -> Set<String> {
            var found = Set<String>()
            func walk(_ folder: String, _ relative: String) {
                for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
                    let rel = relative.isEmpty ? name : relative + "/" + name
                    guard rel != "KnotStore" else { continue }
                    let kind = (try? FileManager.default.attributesOfItem(atPath: folder + "/" + name))?[.type]
                    found.insert(rel)
                    if (kind as? FileAttributeType) == .typeDirectory { walk(folder + "/" + name, rel) }
                }
            }
            walk(scratch.path, "")
            return found
        }
    }

    /// Finding 1 of the review of pull request 60: `remove` and `removePartials` give the
    /// layer the path they checked. A `..` after a link inside the root is worked out from the
    /// text, so it names a path in the root, never one the system reaches through the link.
    @Test func removeGivesTheLayerThePathItChecked() throws {
        let tree = try Tree()
        let files = StoreLocations.testing(root: tree.scratch).durableFiles(layer: PosixFileLayer())
        try? files.remove(tree.path("KnotStore/Leak/../v2"))
        try? files.removePartials(in: tree.path("KnotStore/Leak/.."))
        #expect(FileManager.default.fileExists(atPath: tree.path("v2").path), "v2, beside the root, is not removed.")
        #expect(FileManager.default.fileExists(atPath: tree.path(".q.partial").path), "Nor the partial beside it.")
    }

    /// Finding 6, of the orchestrator, from the review's table: `remove` and `removePartials`
    /// refuse a path with a link among its folders below the root, as `place` does, with the
    /// same error, and a folder that is not there is nothing to remove, and no error.
    @Test func removeRefusesALinkBelowTheRoot() throws {
        let tree = try Tree()
        let files = StoreLocations.testing(root: tree.scratch).durableFiles(layer: PosixFileLayer())
        for (text, act) in [
            ("KnotStore/Leak/v1", { (url: URL) throws(KnotError) in try files.remove(url) }),
            ("KnotStore/A/Last/v1", { (url: URL) throws(KnotError) in try files.remove(url) }),
            ("KnotStore/Leak", { (url: URL) throws(KnotError) in try files.removePartials(in: url) }),
            ("KnotStore/A/Last", { (url: URL) throws(KnotError) in try files.removePartials(in: url) }),
        ] {
            #expect("\(text)", performing: { try act(tree.path(text)) }, throws: { error in
                (error as? KnotError)?.context.posixError == ENOTDIR
            })
        }
        #expect(FileManager.default.fileExists(atPath: tree.path("outside/v1").path), "v1, outside, is not removed.")
        #expect(FileManager.default.fileExists(atPath: tree.path("outside/.p.partial").path))
        try files.remove(tree.path("KnotStore/Missing/f.json"))
        try files.removePartials(in: tree.path("KnotStore/Missing"))
    }
}
