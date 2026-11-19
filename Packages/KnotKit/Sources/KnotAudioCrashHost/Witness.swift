import Foundation

/// The child's account of what it has done, kept where its parent can read it after a kill.
///
/// After every append and every sync the child writes two counts, in frames, at the start of
/// a small file: what `append` has accepted, and what the last sync pushed to the drive. A
/// `pwrite` lands in the kernel before it returns, so the file survives SIGKILL and tells the
/// parent how far the recording had got, independently of what the audio file says.
final class Witness {
    private let descriptor: Int32

    init(url: URL) throws(HostError) {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        }
        guard descriptor >= 0 else { throw .system("open witness", errno) }
        self.descriptor = descriptor
        record(appended: 0, durable: 0)
    }

    deinit { close(descriptor) }

    func record(appended: Int64, durable: Int64) {
        var counts = (appended.littleEndian, durable.littleEndian)
        _ = withUnsafeBytes(of: &counts) { bytes in
            pwrite(descriptor, bytes.baseAddress, bytes.count, 0)
        }
    }

    /// The two counts in a witness file, or nil if there is none.
    static func read(_ url: URL) -> (appended: Int64, durable: Int64)? {
        guard let data = try? Data(contentsOf: url), data.count >= 16 else { return nil }
        let appended = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int64.self) }
        let durable = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: Int64.self) }
        return (Int64(littleEndian: appended), Int64(littleEndian: durable))
    }
}

/// Writes a small file the way `DurableFile` will (docs/architecture.md §3): write a temporary
/// file, sync it, rename it into place, sync the folder.
///
/// It stands in for the recording's manifest, which the recorder writes before the first
/// sample, so that the start latency includes what that write costs. The real manifest is a
/// `CaptureManifest` from KnotCore, which WP-02 adds.
enum StandInManifest {
    static func write(to url: URL) throws(HostError) {
        let temporary = url.appendingPathExtension("tmp")
        let body = Data(String(repeating: "{\"stand-in\":true}", count: 12).utf8)
        let descriptor = temporary.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        }
        guard descriptor >= 0 else { throw .system("open manifest", errno) }
        defer { close(descriptor) }
        let written = body.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard written == body.count else { throw .system("write manifest", errno) }
        guard fcntl(descriptor, F_FULLFSYNC) == 0 else { throw .system("sync manifest", errno) }
        guard rename(temporary.path, url.path) == 0 else { throw .system("rename manifest", errno) }
        let folder = open(url.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        guard folder >= 0 else { throw .system("open folder", errno) }
        defer { close(folder) }
        guard fcntl(folder, F_FULLFSYNC) == 0 else { throw .system("sync folder", errno) }
    }
}
