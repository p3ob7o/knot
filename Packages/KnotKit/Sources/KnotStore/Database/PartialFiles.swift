import Darwin
import Foundation
import KnotCore
import Synchronization

/// The partial files of the store's own writers: a store being made and a copy being written.
/// Each is named for the process that writes it, and this process keeps the ones it is writing,
/// so that an open, which removes what a crash left, removes only what a dead writer left: never
/// a partial file that a writer of this process, or a process that still runs, is writing.
///
/// A partial file's name is `.<final name>.p<process ID>.<UUID>.partial`.
enum PartialFiles {
    /// The names of the partial files this process is writing now. A name is enough: its process
    /// ID and UUID make it unique, and it reads the same however its folder is written, with
    /// `/private` or without, through a link or not, before the file exists and after. A path
    /// would not: `URL.standardizedFileURL` drops a leading `/private` only once the file exists.
    private static let writing = Mutex<Set<String>>([])

    /// A new partial file for `final` in `folder`, this process's until `finished(_:)`.
    static func make(for final: String, in folder: URL) -> URL {
        let url = folder.appending(
            path: ".\(final).p\(getpid()).\(UUID().uuidString.lowercased())\(DurableFile.partialSuffix)",
            directoryHint: .notDirectory)
        let name = url.lastPathComponent
        writing.withLock { _ = $0.insert(name) }
        return url
    }

    /// The writer of `url` is done with it: published, or removed.
    static func finished(_ url: URL) {
        let name = url.lastPathComponent
        writing.withLock { _ = $0.remove(name) }
    }

    /// Whether the entry `name`, a partial file or one of its journals, is what a dead writer
    /// left: not a file this process is writing, and not one of a process that still runs. A
    /// name of the older form, with no writer, is a leftover.
    static func isLeftover(_ name: String) -> Bool {
        var base = name
        for suffix in ["-wal", "-shm", "-journal"] where base.hasSuffix(suffix) { base.removeLast(suffix.count) }
        if writing.withLock({ $0.contains(base) }) { return false }
        guard let writer = writer(of: base), writer != getpid() else { return true }
        // Signal 0 only asks whether the process exists. One that exists and is another user's,
        // or the system's, answers with `EPERM`: it runs.
        return kill(writer, 0) != 0 && errno == ESRCH
    }

    /// The process that a partial file's name says writes it.
    static func writer(of name: String) -> pid_t? {
        for part in name.split(separator: ".") where part.count > 1 && part.hasPrefix("p") {
            let digits = part.dropFirst()
            if digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber), let process = pid_t(digits) {
                return process
            }
        }
        return nil
    }
}
