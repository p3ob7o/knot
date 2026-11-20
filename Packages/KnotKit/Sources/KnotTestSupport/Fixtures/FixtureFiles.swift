import CryptoKit
import Foundation

/// A fixture that is missing or changed (Fixtures/README.md). It fails the test, and never
/// skips it: skipping is only for a model that is unavailable (docs/architecture.md §17).
public struct FixtureFailure: Error, CustomStringConvertible, Equatable {
    /// `fixture_missing` or `fixture_changed`.
    public let code: String
    /// The fixture's path from the repository's root, such as `Fixtures/ink/line.json`.
    public let path: String
    /// What happened and how to put it right.
    public let message: String

    public var description: String { "\(code): \(message)" }
}

/// The one lookup of the shared fixtures, for every package's tests (Fixtures/README.md).
///
/// A test finds `Fixtures/manifest.json` by walking up from its own source file. A committed
/// file is checked against its SHA-256 in `Fixtures/manifest.json`, and a generated one, which
/// each Mac makes, against `Fixtures/generated/manifest.json`. A manifest that is missing or
/// cannot be read, and a file it does not describe, fail too: nothing is returned unchecked.
public enum FixtureFiles {
    /// The `Fixtures/` folder above `file`.
    public static func folder(from file: StaticString = #filePath) throws(FixtureFailure) -> URL {
        var url = URL(fileURLWithPath: "\(file)")
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            let fixtures = url.appending(path: "Fixtures", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: fixtures.appending(path: "manifest.json").path) {
                return fixtures
            }
        }
        throw FixtureFailure(
            code: "fixture_missing", path: "Fixtures/manifest.json",
            message: "No Fixtures/manifest.json above \(file). Restore it with `git checkout -- Fixtures`.")
    }

    /// A fixture by its path inside `Fixtures/`, such as `ink/line.json` or
    /// `generated/audio/clean.wav`, checked against its manifest.
    public static func url(_ path: String, from file: StaticString = #filePath) throws(FixtureFailure) -> URL {
        try url(path, in: folder(from: file))
    }

    /// The same, inside a given `Fixtures/` folder.
    public static func url(_ path: String, in fixtures: URL) throws(FixtureFailure) -> URL {
        let shown = "Fixtures/\(path)"
        let generated = path.hasPrefix("generated/")
        guard !path.split(separator: "/").contains(".."), !path.hasPrefix("/") else {
            throw FixtureFailure(code: "fixture_missing", path: shown, message: "\(shown) is not inside Fixtures/.")
        }
        let target = fixtures.appending(path: path, directoryHint: .notDirectory)
        guard let data = FileManager.default.contents(atPath: target.path) else {
            let message =
                generated
                ? "\(shown) has not been made on this Mac (looked under \(fixtures.deletingLastPathComponent().path)). "
                    + "Run `Fixtures/tools/generate.sh --audio` to speak the audio fixtures with the system voices."
                : "\(shown) is not in this checkout. Restore it with `git checkout -- Fixtures`."
            throw FixtureFailure(code: "fixture_missing", path: shown, message: message)
        }
        let manifestName = generated ? "Fixtures/generated/manifest.json" : "Fixtures/manifest.json"
        let manifest = fixtures.appending(path: generated ? "generated/manifest.json" : "manifest.json")
        guard let sums = checksums(in: manifest) else {
            let fix =
                generated
                ? "Run `Fixtures/tools/generate.sh --audio` to make this Mac's audio and its manifest."
                : "Restore it with `git checkout -- Fixtures/manifest.json`."
            throw FixtureFailure(
                code: "fixture_missing", path: manifestName, message: "\(manifestName) is missing or unreadable. \(fix)"
            )
        }
        guard let expected = sums[path] else {
            throw FixtureFailure(
                code: "fixture_missing", path: shown,
                message: "\(shown) is not described in \(manifestName), so it cannot be checked. "
                    + "Add it to the manifest with `Fixtures/tools/generate.sh --committed`.")
        }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else {
            let fix =
                generated
                ? "Make it again with `Fixtures/tools/generate.sh --audio`."
                : "Restore it with `git checkout -- \(shown)`, or regenerate the committed files and the manifest together."
            throw FixtureFailure(
                code: "fixture_changed", path: shown,
                message: "\(shown) does not match Fixtures/\(generated ? "generated/" : "")manifest.json. \(fix)")
        }
        return target
    }

    /// The checksum of each file a manifest describes, by its path inside `Fixtures/`.
    static func checksums(in manifest: URL) -> [String: String]? {
        guard let data = FileManager.default.contents(atPath: manifest.path),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var sums: [String: String] = [:]
        let pairs = [("file", "sha256"), ("reference", "referenceSha256"), ("preview", "previewSha256")]
        for list in object.values.compactMap({ $0 as? [[String: Any]] }) {
            for entry in list {
                for (pathKey, sumKey) in pairs {
                    if let path = entry[pathKey] as? String, let sum = entry[sumKey] as? String { sums[path] = sum }
                }
            }
        }
        return sums
    }
}
