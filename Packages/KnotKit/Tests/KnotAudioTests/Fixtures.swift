import Foundation

/// Finds WP-04's fixtures the way Fixtures/README.md says tests find them: walk up from this
/// file to the first folder that holds `Fixtures/manifest.json`.
///
/// KnotTestSupport should hold this once for every package (Fixtures/README.md). Until the
/// orchestrator assigns that helper, KnotAudio's tests keep their own copy.
enum Fixture {
    struct Missing: Error, CustomStringConvertible {
        let description: String
    }

    /// The repository's root: the first folder above this file that holds the fixtures' manifest.
    static func repositoryRoot(from file: String = #filePath) throws -> URL {
        var folder = URL(fileURLWithPath: file).deletingLastPathComponent()
        while folder.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("Fixtures/manifest.json").path) {
                return folder
            }
            folder.deleteLastPathComponent()
        }
        throw Missing(description: "fixture_missing: no Fixtures/manifest.json above \(file).")
    }

    /// A clip of the generated audio, such as `clean.wav`. Audio is made on each Mac and not
    /// committed, so a clip that has not been made fails with the README's message.
    static func generatedAudio(_ name: String) throws -> URL {
        let root = try repositoryRoot()
        let relative = "Fixtures/generated/audio/\(name)"
        let url = root.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Missing(
                description: """
                    fixture_missing: \(relative) has not been made on this Mac (looked under \(root.path)).
                    Run `Fixtures/tools/generate.sh --audio` to speak the audio fixtures with the system voices.
                    """)
        }
        return url
    }
}

/// A new, empty folder for one test's files, removed when the test ends.
struct ScratchFolder: ~Copyable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("KnotAudioTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    deinit { try? FileManager.default.removeItem(at: url) }
}
