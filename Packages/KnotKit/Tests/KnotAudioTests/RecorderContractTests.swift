import Foundation
import KnotCore
import KnotTestSupport
import Testing

@testable import KnotAudio

/// The live recorder runs the `Recorder` contract suite unchanged, on injected audio: each
/// subject is a recorder over a store of its own, fed without end until it is stopped, and seen
/// through the file system, never through the recorder.
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
            read: { try? Data(contentsOf: $0) })
    }
}
