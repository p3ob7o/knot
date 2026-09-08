import Foundation

func makeFixture() throws -> (url: URL, cleanup: () -> Void) {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "KnotLegacyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return (url, { try? FileManager.default.removeItem(at: url) })
}
