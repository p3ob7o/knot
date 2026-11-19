import Foundation
import UIKit

/// The recording's manifest, written before the first sample (docs/architecture.md §6, rule 3),
/// in the app's own container with the protection class §7 proposes.
enum Manifests {
    struct Manifest: Codable {
        var captureID: UUID
        var startedAt: Date
        var launch: Date?
        var pid: Int32
        var outcome: String
        var finishedAt: Date?
    }

    static let protection = FileProtectionType.completeUntilFirstUserAuthentication

    static var folder: URL {
        let base = URL.applicationSupportDirectory.appending(path: "SP1/Recording", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true, attributes: [.protectionKey: protection])
        return base
    }

    static func audioURL(_ id: UUID) -> URL { folder.appending(path: "\(id.uuidString).caf") }
    static func manifestURL(_ id: UUID) -> URL { folder.appending(path: "\(id.uuidString).json") }

    /// Writes the manifest and returns where the audio goes.
    static func begin(captureID: UUID, startedAt: Date, launch: Date?) throws -> URL {
        let manifest = Manifest(
            captureID: captureID, startedAt: startedAt, launch: launch, pid: SP1Process.pid, outcome: "open")
        try write(manifest)
        let actual = (try? FileManager.default.attributesOfItem(atPath: manifestURL(captureID).path))?[.protectionKey]
        SP1Log.record(
            "manifest.written",
            ["capture": captureID.uuidString, "protection": (actual as? FileProtectionType)?.rawValue ?? "?"])
        return audioURL(captureID)
    }

    static func finish(captureID: UUID, outcome: String) {
        guard var manifest = read(manifestURL(captureID)) else { return }
        manifest.outcome = outcome
        manifest.finishedAt = .now
        try? write(manifest)
    }

    static func all() -> [Manifest] {
        let urls =
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap(read)
    }

    static func write(_ manifest: Manifest) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(
            to: manifestURL(manifest.captureID),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func read(_ url: URL) -> Manifest? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
    }
}

/// Turns recordings that a dead launch left open into recovered ones, beside the new press
/// (product spec §4.2). WP-12 owns real recovery. The spike only proves the case is seen.
enum Recovery {
    static func recoverOrphans(currentLaunch: Date?) {
        for manifest in Manifests.all() where manifest.outcome == "open" {
            let sameLaunch: Bool =
                if let launch = manifest.launch, let currentLaunch {
                    abs(launch.timeIntervalSince(currentLaunch)) < 0.001 && manifest.pid == SP1Process.pid
                } else {
                    false
                }
            guard !sameLaunch else { continue }
            let bytes =
                (try? FileManager.default.attributesOfItem(atPath: Manifests.audioURL(manifest.captureID).path))?[
                    .size] as? Int64
            Manifests.finish(captureID: manifest.captureID, outcome: "recovered")
            SP1Log.record(
                "recovery.orphan",
                ["capture": manifest.captureID.uuidString, "bytes": bytes.map(String.init) ?? "missing"])
        }
    }
}

/// Which file protection classes can be written, and read back, at this moment. Seed files of
/// each class are written once while the phone is unlocked, and read back at each press.
enum ProtectionProbe {
    private static let classes: [(String, FileProtectionType, Data.WritingOptions)] = [
        ("complete", .complete, .completeFileProtection),
        ("unlessOpen", .completeUnlessOpen, .completeFileProtectionUnlessOpen),
        ("untilFirstAuth", .completeUntilFirstUserAuthentication, .completeFileProtectionUntilFirstUserAuthentication),
        ("none", .none, .noFileProtection),
    ]

    private static var folder: URL {
        let url = URL.applicationSupportDirectory.appending(path: "SP1/Probe", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes the seed files if the phone is unlocked and they are missing.
    @MainActor
    static func seedIfPossible() {
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        for (name, _, option) in classes {
            let url = folder.appending(path: "seed-\(name)")
            if !FileManager.default.fileExists(atPath: url.path) {
                try? Data("seed".utf8).write(to: url, options: [.atomic, option])
            }
        }
    }

    /// Returns a compact summary, such as `w:complete=ok,…;r:complete=257,…`, and logs it.
    @discardableResult
    static func run(label: String) -> String {
        var writes: [String] = []
        var reads: [String] = []
        for (name, _, option) in classes {
            let url = folder.appending(path: "probe-\(name)")
            try? FileManager.default.removeItem(at: url)
            do {
                try Data("p".utf8).write(to: url, options: [option])
                writes.append("\(name)=ok")
            } catch {
                writes.append("\(name)=\((error as NSError).code)")
            }
            do {
                _ = try Data(contentsOf: folder.appending(path: "seed-\(name)"))
                reads.append("\(name)=ok")
            } catch {
                reads.append("\(name)=\((error as NSError).code)")
            }
        }
        let summary = "w:" + writes.joined(separator: ",") + ";r:" + reads.joined(separator: ",")
        SP1Log.record("probe.protection", ["label": label, "result": summary])
        return summary
    }
}
