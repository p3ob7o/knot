import Foundation

/// Append-only spool of notes that failed to write to the vault. Persists as
/// JSON Lines (one note per line) so it's easy to inspect manually if needed.
///
/// v0 only writes to the queue; flush logic is delegated to the host app.
public final class Queue: @unchecked Sendable {
    public let url: URL

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.url = directory.appending(path: "knot-queue.jsonl")
    }

    public func enqueue(_ note: Note) throws {
        var data = try JSONEncoder().encode(note)
        data.append(0x0A) // newline

        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: [.atomic])
        }
    }

    public func loadAll() throws -> [Note] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let raw = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        return raw.split(whereSeparator: { $0.isNewline }).compactMap { line in
            try? decoder.decode(Note.self, from: Data(line.utf8))
        }
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
