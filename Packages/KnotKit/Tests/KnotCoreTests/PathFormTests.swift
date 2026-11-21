import Foundation
import Testing

@testable import KnotCore

/// A store's root is the same folder however its path is written: with or without `/private`,
/// through a symbolic link or not, before or after its folders exist. A write outside the root
/// is still refused. These run on the real file system, under the temporary folder.
@Suite struct PathFormTests {
    /// A new real folder's path under the temporary folder, not made yet, in its two forms: the
    /// one without `/private`, as `FileManager` gives the temporary folder, and the one with
    /// it, as an app group's container is given on a device.
    static func newFolder() throws -> (plain: URL, privateForm: URL) {
        let base = FileManager.default.temporaryDirectory.appending(
            path: "path-form-\(UUID().uuidString)", directoryHint: .isDirectory)
        let path = base.path
        let plain = path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
        try #require(plain.hasPrefix("/var/") || plain.hasPrefix("/tmp/"), "The temporary folder is in /var or /tmp.")
        let plainURL = URL(fileURLWithPath: plain, isDirectory: true)
        return (plainURL, URL(fileURLWithPath: "/private" + plain, isDirectory: true))
    }

    static func contents(_ url: URL) -> Data? { FileManager.default.contents(atPath: url.path) }

    enum RootExists: CaseIterable { case notYet, already }

    /// The root given in one form, and every path below it in either: the folders are made,
    /// a file is placed, then placed again, whether the root existed before or not.
    @Test(arguments: [true, false], RootExists.allCases)
    func theRootMatchesPathsWrittenEitherWay(rootWithPrivate: Bool, root exists: RootExists) throws {
        let (plain, privateForm) = try Self.newFolder()
        if exists == .already { try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true) }
        let root = rootWithPrivate ? privateForm : plain
        let durable = DurableFile(layer: PosixFileLayer(), root: root)
        for form in [privateForm, plain, privateForm] {
            let inbox = form.appending(path: "Inbox", directoryHint: .isDirectory)
            try durable.makeFolder(inbox)
            try durable.place(Data("\(form.path.count)".utf8), at: inbox.appending(path: "a.json"))
            #expect(Self.contents(plain.appending(path: "Inbox/a.json")) == Data("\(form.path.count)".utf8))
        }
    }

    /// The reported case on main: a root given in the `/private` form, its folders made, then a
    /// placement, which failed with `write_failed` once the folders existed.
    @Test func aRootGivenWithPrivateTakesAPlacementBelowIt() throws {
        let (plain, privateForm) = try Self.newFolder()
        let inbox = privateForm.appending(path: "Inbox", directoryHint: .isDirectory)
        let durable = DurableFile(layer: PosixFileLayer(), root: privateForm)
        try durable.makeFolder(inbox)
        try durable.place(Data("one".utf8), at: inbox.appending(path: "a.json"))
        #expect(Self.contents(plain.appending(path: "Inbox/a.json")) == Data("one".utf8))
    }

    /// A root given through a symbolic link to its real folder, and paths written through the
    /// real folder, and the other way round.
    @Test func aRootGivenThroughALinkIsItsRealFolder() throws {
        let (real, _) = try Self.newFolder()
        let (linkFolder, _) = try Self.newFolder()
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linkFolder, withIntermediateDirectories: true)
        let link = linkFolder.appending(path: "store", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        for (root, written) in [(link, real), (real, link)] {
            let durable = DurableFile(layer: PosixFileLayer(), root: root)
            let file = written.appending(path: "Assets/a.bin")
            try durable.place(Data("\(root.path.count)".utf8), at: file)
            #expect(Self.contents(real.appending(path: "Assets/a.bin")) == Data("\(root.path.count)".utf8))
        }
    }

    /// The check that keeps a write inside the root still holds: a folder beside the root, a
    /// `..` that leads out, and a symbolic link inside the root that leads out are refused,
    /// with `write_failed`, and nothing is written outside.
    @Test func aWriteOutsideTheRootIsStillRefused() throws {
        let (plain, privateForm) = try Self.newFolder()
        let (outside, _) = try Self.newFolder()
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let durable = DurableFile(layer: PosixFileLayer(), root: privateForm)
        let link = plain.appending(path: "Leak", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let refused: [(String, URL)] = [
            ("beside", outside.appending(path: "a.json")),
            ("beside, with /private", URL(fileURLWithPath: "/private" + outside.path).appending(path: "a.json")),
            ("by ..", URL(fileURLWithPath: privateForm.path + "/../" + outside.lastPathComponent + "/b.json")),
            (
                "by .. from a folder",
                URL(fileURLWithPath: plain.path + "/Inbox/../../" + outside.lastPathComponent + "/c.json")
            ),
            ("through a link", link.appending(path: "d.json")),
            ("through a link, with /private", URL(fileURLWithPath: "/private" + link.path).appending(path: "e.json")),
        ]
        for (label, target) in refused {
            #expect(throws: KnotError.self, "\(label)") { try durable.place(Data("x".utf8), at: target) }
            #expect(throws: KnotError.self, "\(label)") { try durable.makeFolder(target.deletingLastPathComponent()) }
        }
        let leaked = try FileManager.default.contentsOfDirectory(atPath: outside.path)
        #expect(leaked.isEmpty, "Nothing is written outside the root: \(leaked)")
    }

    /// A store rooted in the `/private` form places a path written in either form under its
    /// root, and says that root holds it.
    @Test func storeFilesPlaceAPathWrittenEitherWay() throws {
        let (plain, privateForm) = try Self.newFolder()
        // The folder a store's root sits in exists, as an app's container does.
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let locations = StoreLocations.testing(root: privateForm)
        let files = locations.durableFiles(layer: PosixFileLayer())
        let inPrivate = locations.inbox.appending(path: "a.json")
        let inPlain = URL(fileURLWithPath: String(locations.inbox.path.dropFirst("/private".count)))
            .appending(path: "b.json")
        try files.place(Data("one".utf8), at: inPrivate)
        try files.place(Data("two".utf8), at: inPlain)
        #expect(files.root(for: inPrivate) != nil && files.root(for: inPrivate) == files.root(for: inPlain))
        let inbox = plain.appending(path: locations.storeRoot.lastPathComponent).appending(path: "Inbox")
        #expect(Self.contents(inbox.appending(path: "a.json")) == Data("one".utf8))
        #expect(Self.contents(inbox.appending(path: "b.json")) == Data("two".utf8))
    }
}
