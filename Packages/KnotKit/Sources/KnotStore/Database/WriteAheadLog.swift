import Foundation
import KnotCore

/// Reads a database's write-ahead log in place, without SQLite and without copying it, for the
/// one thing an open must know before any connection touches the store: the schema version of
/// the newest committed image of the database's first page (docs/architecture.md §7). SQLite
/// reads the log only through a shared-memory file that it makes beside the database, which an
/// open that refuses a newer store must not do.
///
/// The log is read as SQLite recovers it (https://www.sqlite.org/fileformat2.html#walformat):
/// a 32-byte header with its magic, page size, salts and checksum, then frames of a 24-byte
/// header and a page. Frames are taken in order, each only while its salts are the header's and
/// the running checksum matches, and the first frame that fails ends the log. A frame's page
/// counts once a commit frame, one that gives the database's size, follows it or is it. A log
/// whose header does not check is one SQLite ignores, and so is this reading.
enum WriteAheadLog {
    /// The schema version, `PRAGMA user_version`, of the newest committed image of page 1 in the
    /// log at `url`, or `nil` when there is no log or it holds no committed image of page 1. A
    /// log that cannot be read throws with the error that stopped the reading; a log of a format
    /// version SQLite would not open is `store_damaged`.
    static func committedVersion(of url: URL) throws(KnotError) -> Int? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            let mapped = StoreErrors.fileError(error)
            if mapped.code == KnotError.notFound.code { return nil }
            throw mapped
        }
        defer { try? handle.close() }
        do {
            return try committedVersion(reading: handle)
        } catch let error as KnotError {
            throw error
        } catch {
            throw StoreErrors.fileError(error)
        }
    }

    /// The magic of a log whose checksums read 32-bit words little-endian, and with its low bit
    /// set, big-endian.
    static let magic: UInt32 = 0x377f_0682
    /// The only log format version SQLite writes and reads.
    static let formatVersion: UInt32 = 3_007_000
    static let headerSize = 32
    static let frameHeaderSize = 24
    /// Where `user_version` is in the database's header, on page 1.
    static let userVersionOffset = 60

    private static func committedVersion(reading handle: FileHandle) throws -> Int? {
        guard let header = try handle.read(upToCount: headerSize), header.count == headerSize else { return nil }
        let found = word(header, 0)
        guard found | 1 == magic | 1 else { return nil }
        let bigEndianSums = found & 1 == 1
        guard word(header, 4) == formatVersion else { throw KnotError.storeDamaged }
        let pageSize = Int(word(header, 8))
        guard (512...65_536).contains(pageSize), pageSize & (pageSize - 1) == 0 else { return nil }
        let salts = (word(header, 16), word(header, 20))
        var sum = checksum(header, range: 0..<24, bigEndian: bigEndianSums, from: (0, 0))
        guard sum == (word(header, 24), word(header, 28)) else { return nil }
        var pending: Data?
        var committed: Data?
        while let frame = try handle.read(upToCount: frameHeaderSize + pageSize),
            frame.count == frameHeaderSize + pageSize
        {
            let page = word(frame, 0)
            guard page != 0, (word(frame, 8), word(frame, 12)) == salts else { break }
            sum = checksum(frame, range: 0..<8, bigEndian: bigEndianSums, from: sum)
            sum = checksum(frame, range: frameHeaderSize..<frame.count, bigEndian: bigEndianSums, from: sum)
            guard sum == (word(frame, 16), word(frame, 20)) else { break }
            if page == 1 {
                pending = frame.subdata(in: frameHeaderSize..<(frameHeaderSize + userVersionOffset + 4))
            }
            // A commit frame gives the database's size in pages after the commit.
            if word(frame, 4) != 0 {
                if let pending { committed = pending }
                pending = nil
            }
        }
        guard let image = committed else { return nil }
        return Int(Int32(bitPattern: word(image, userVersionOffset)))
    }

    /// The big-endian 32-bit word at `offset`, as the log's and the database's headers write them.
    private static func word(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    /// SQLite's checksum of the log: over pairs of 32-bit words, each pair adding to both sums,
    /// the words read in the order the log's magic gives.
    private static func checksum(
        _ data: Data, range: Range<Int>, bigEndian: Bool, from start: (UInt32, UInt32)
    ) -> (UInt32, UInt32) {
        var (first, second) = start
        data.withUnsafeBytes { bytes in
            var offset = range.lowerBound
            while offset + 8 <= range.upperBound {
                var a = bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                var b = bytes.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)
                if bigEndian {
                    a = UInt32(bigEndian: a)
                    b = UInt32(bigEndian: b)
                } else {
                    a = UInt32(littleEndian: a)
                    b = UInt32(littleEndian: b)
                }
                first = first &+ a &+ second
                second = second &+ b &+ first
                offset += 8
            }
        }
        return (first, second)
    }
}
