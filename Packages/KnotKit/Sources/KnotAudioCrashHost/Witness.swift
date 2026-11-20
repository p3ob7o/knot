import Foundation

/// The child's account of what it has done, kept where its parent can read it after a kill.
///
/// After every buffer the recorder takes, and after every sync it reports, the child writes two
/// counts, in frames, at the start of a small file: what the recorder has taken, and what it has
/// said is durable. A `pwrite` lands in the kernel before it returns, so the file survives
/// SIGKILL and tells the parent how far the recording had got, whatever the audio file says.
final class Witness: Sendable {
    private let descriptor: Int32

    init(url: URL) throws(HostError) {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        }
        guard descriptor >= 0 else { throw .system("open witness", errno) }
        self.descriptor = descriptor
        write(at: 0, 0)
        write(at: 8, 0)
    }

    deinit { close(descriptor) }

    /// The frames the recorder has taken so far.
    func taken(_ frames: Int64) { write(at: 0, frames) }

    /// The frames the recorder has said are durable.
    func durable(_ frames: Int64) { write(at: 8, frames) }

    private func write(at offset: off_t, _ value: Int64) {
        var bytes = value.littleEndian
        _ = withUnsafeBytes(of: &bytes) { pwrite(descriptor, $0.baseAddress, $0.count, offset) }
    }

    /// The two counts in a witness file, or nil if there is none.
    static func read(_ url: URL) -> (taken: Int64, durable: Int64)? {
        guard let data = try? Data(contentsOf: url), data.count >= 16 else { return nil }
        let taken = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int64.self) }
        let durable = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: Int64.self) }
        return (Int64(littleEndian: taken), Int64(littleEndian: durable))
    }
}
