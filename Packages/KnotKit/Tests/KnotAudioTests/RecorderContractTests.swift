import Foundation
import KnotCore
import KnotTestSupport
import Testing

@testable import KnotAudio

/// The live recorder runs the `Recorder` contract suite unchanged, on injected audio: each
/// subject is a recorder over a store of its own, fed without end until it is stopped, and seen
/// through the file system, never through the recorder. A file the recorder cannot read is one
/// whose permissions refuse every reader, as one protected while the device is locked refuses
/// the recorder, and a file removed without the recorder is removed by the file manager.
@Test("The live recorder passes the Recorder contract", .tags(.contract))
func liveRecorderPassesTheRecorderContract() async throws {
    let folders = TemporaryFolders()
    defer { folders.removeAll() }
    try await RecorderContract.run {
        let locations = StoreLocations.testing(root: try folders.make())
        return RecorderSubject(
            recorder: recorder(locations, input: injected()), locations: locations,
            exists: { FileManager.default.fileExists(atPath: $0.path) },
            size: { url in
                (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
            },
            read: { try? Data(contentsOf: $0) },
            setReadable: { url, readable in
                try? FileManager.default.setAttributes(
                    [.posixPermissions: readable ? 0o644 : 0], ofItemAtPath: url.path)
            },
            remove: { try? FileManager.default.removeItem(at: $0) })
    }
}
