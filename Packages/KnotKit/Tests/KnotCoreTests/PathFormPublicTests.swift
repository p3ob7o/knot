import Foundation
import KnotCore
import Testing

/// `PathForm.real(_:)` as a module outside KnotCore calls it, with no `@testable` import: one
/// folder gives one real path, written with `/private` or without, before it exists and after.
@Suite struct PathFormPublicTests {
    @Test func oneFolderHasOneRealPathInEitherFormBeforeAndAfterItExists() throws {
        let plain = NSTemporaryDirectory()
        try #require(plain.hasPrefix("/var/"), "The test needs a folder below /private/var.")
        let name = "knot-path-form-\(UUID().uuidString)"
        let without = URL(fileURLWithPath: plain, isDirectory: true).appending(path: name, directoryHint: .isDirectory)
        let withPrivate = URL(fileURLWithPath: "/private" + plain, isDirectory: true)
            .appending(path: name, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: without) }
        let inbox = { (root: URL) in root.appending(path: "Inbox", directoryHint: .isDirectory) }
        let before = [PathForm.real(inbox(without)), PathForm.real(inbox(withPrivate))]
        try FileManager.default.createDirectory(at: inbox(withPrivate), withIntermediateDirectories: true)
        let after = [PathForm.real(inbox(without)), PathForm.real(inbox(withPrivate))]
        #expect(Set(before + after).count == 1, "One folder, one real path: \(Set(before + after).count) found.")
        #expect(PathForm.real(inbox(without).appending(path: "..").appending(path: "Inbox")) == after[0])
    }
}
