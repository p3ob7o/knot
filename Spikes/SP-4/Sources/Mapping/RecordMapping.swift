// Notes, segments, their deletions and assets as CloudKit records (docs/architecture.md §11).
// Everything here builds and reads CKRecord values locally: no container, no database.

import CloudKit
import Foundation

enum Zones {
    /// Notes, segments and settings, managed by CKSyncEngine.
    static let stream = CKRecordZone.ID(zoneName: "Stream", ownerName: CKCurrentUserDefaultName)
    /// One record per asset, kept out of the engine's fetches and read on demand.
    static let attachments = CKRecordZone.ID(zoneName: "Attachments", ownerName: CKCurrentUserDefaultName)
}

enum MappingError: Error, Equatable {
    case unknownRecordType(String)
    case missingField(String)
    case badValue(String)
}

/// The schema as the spike writes it. Field names are final only when the report says so.
enum Schema {
    enum Note {
        static let type = "Note"
        static let title = "title"                // encrypted
        static let titleOrigin = "titleOrigin"
        static let titleEditedAt = "titleEditedAt"
        static let createdAt = "createdAt"
        static let closedAt = "closedAt"
        static let deletedAt = "deletedAt"
    }
    enum Segment {
        static let type = "Segment"
        static let note = "note"                  // a reference with no action, so it can change
        static let noteGeneration = "noteGeneration"
        static let kind = "kind"
        static let origin = "origin"
        static let startedAt = "startedAt"
        static let endedAt = "endedAt"
        static let text = "text"                  // encrypted
        static let textOrigin = "textOrigin"
        static let rawTranscript = "rawTranscript" // encrypted
        static let processingOwner = "processingOwner"
        static let ownerGeneration = "ownerGeneration"
        static let state = "state"
        static let assetID = "assetID"
        static let assetUpload = "assetUpload"    // localOnly | uploading | published (§11)
        static let conflictOf = "conflictOf"
        static let deletedAt = "deletedAt"
    }
    enum Asset {
        static let type = "Asset"
        static let segmentID = "segmentID"
        static let kind = "kind"
        static let byteCount = "byteCount"
        static let sha256 = "sha256"
        static let file = "file"                  // CKAsset, encrypted by CloudKit by default
        /// What an on-demand metadata fetch asks for: everything but the file.
        static let metadataKeys = [segmentID, kind, byteCount, sha256]
    }
    enum ZoneIdentity {
        /// Written once when the Stream zone is made, so a zone removed and made again is a
        /// different zone (§11, account isolation).
        static let type = "ZoneIdentity"
        static let recordName = "zone-identity"
        static let identity = "identity"
    }

    static let encrypted: Set<String> = [Note.title, Segment.text, Segment.rawTranscript]
}

struct RecordMapping: Sendable {
    /// CKRecord's documentation and its header: "the data that a record stores must not
    /// exceed 1 MB. Assets don't count toward this limit." Read, not measured. Whether MB
    /// means 10^6 or 2^20 bytes is not said, so the spike takes the smaller.
    static let recordByteLimit = 1_000_000

    func recordID(_ key: RecordKey) -> CKRecord.ID {
        CKRecord.ID(recordName: key.id.uuidString, zoneID: Zones.stream)
    }

    func key(for recordID: CKRecord.ID, type: CKRecord.RecordType) -> RecordKey? {
        guard recordID.zoneID == Zones.stream, let kind = RecordKind(rawValue: type),
              let id = UUID(uuidString: recordID.recordName) else { return nil }
        return RecordKey(kind: kind, id: id)
    }

    // MARK: - Values to records

    /// Writes a value onto the record rebuilt from its saved system fields, or onto a new
    /// record. Only Knot's own fields are set, so a field from a newer build is not in
    /// `changedKeys()` and the server keeps it untouched (§11, newer records).
    func record(for change: RemoteChange, systemFields: Data?) throws -> CKRecord? {
        guard let key = change.key else { return nil }
        let record: CKRecord
        if let systemFields {
            record = try Self.decodeSystemFields(systemFields)
        } else {
            record = CKRecord(recordType: key.kind.rawValue, recordID: recordID(key))
        }
        switch change {
        case .note(let n): write(n, to: record)
        case .segment(let s): write(s, to: record)
        case .deleted: return nil
        }
        return record
    }

    private func write(_ n: NoteValue, to r: CKRecord) {
        r.encryptedValues[Schema.Note.title] = n.title
        r[Schema.Note.titleOrigin] = n.titleOrigin.rawValue
        r[Schema.Note.titleEditedAt] = n.titleEditedAt
        r[Schema.Note.createdAt] = n.createdAt
        r[Schema.Note.closedAt] = n.closedAt
        r[Schema.Note.deletedAt] = n.deletedAt
    }

    private func write(_ s: SegmentValue, to r: CKRecord) {
        r[Schema.Segment.note] = CKRecord.Reference(recordID: recordID(RecordKey(kind: .note, id: s.noteID)),
                                                    action: .none)
        r[Schema.Segment.noteGeneration] = Int64(s.noteGeneration)
        r[Schema.Segment.kind] = s.kind.rawValue
        r[Schema.Segment.origin] = s.origin.rawValue
        r[Schema.Segment.startedAt] = s.startedAt
        r[Schema.Segment.endedAt] = s.endedAt
        r.encryptedValues[Schema.Segment.text] = s.text
        r[Schema.Segment.textOrigin] = s.textOrigin.rawValue
        r.encryptedValues[Schema.Segment.rawTranscript] = s.rawTranscript
        r[Schema.Segment.processingOwner] = s.processingOwner?.uuidString
        r[Schema.Segment.ownerGeneration] = Int64(s.ownerGeneration)
        r[Schema.Segment.state] = s.state.rawValue
        r[Schema.Segment.assetID] = s.assetID?.uuidString
        r[Schema.Segment.conflictOf] = s.conflictOf?.uuidString
        r[Schema.Segment.deletedAt] = s.deletedAt
    }

    // MARK: - Records to values

    func value(from r: CKRecord) throws(MappingError) -> RemoteChange {
        guard let key = key(for: r.recordID, type: r.recordType) else {
            throw .unknownRecordType(r.recordType)
        }
        switch key.kind {
        case .note:
            return .note(NoteValue(
                id: key.id,
                createdAt: try required(r[Schema.Note.createdAt] as? Date, Schema.Note.createdAt),
                title: r.encryptedValues[Schema.Note.title] as? String,
                titleOrigin: Tag(r[Schema.Note.titleOrigin] as? String ?? TitleOrigin.none.rawValue),
                titleEditedAt: r[Schema.Note.titleEditedAt] as? Date,
                closedAt: r[Schema.Note.closedAt] as? Date,
                deletedAt: r[Schema.Note.deletedAt] as? Date))
        case .segment:
            let reference = try required(r[Schema.Segment.note] as? CKRecord.Reference, Schema.Segment.note)
            guard let noteID = UUID(uuidString: reference.recordID.recordName) else {
                throw .badValue(Schema.Segment.note)
            }
            return .segment(SegmentValue(
                id: key.id,
                noteID: noteID,
                noteGeneration: Int(r[Schema.Segment.noteGeneration] as? Int64 ?? 0),
                kind: Tag(try required(r[Schema.Segment.kind] as? String, Schema.Segment.kind)),
                origin: Tag(r[Schema.Segment.origin] as? String ?? "device"),
                startedAt: try required(r[Schema.Segment.startedAt] as? Date, Schema.Segment.startedAt),
                endedAt: r[Schema.Segment.endedAt] as? Date,
                text: r.encryptedValues[Schema.Segment.text] as? String ?? "",
                textOrigin: Tag(r[Schema.Segment.textOrigin] as? String ?? TextOrigin.typed.rawValue),
                rawTranscript: r.encryptedValues[Schema.Segment.rawTranscript] as? String,
                processingOwner: (r[Schema.Segment.processingOwner] as? String).flatMap(UUID.init(uuidString:)),
                ownerGeneration: Int(r[Schema.Segment.ownerGeneration] as? Int64 ?? 0),
                state: Tag(r[Schema.Segment.state] as? String ?? "ready"),
                assetID: (r[Schema.Segment.assetID] as? String).flatMap(UUID.init(uuidString:)),
                conflictOf: (r[Schema.Segment.conflictOf] as? String).flatMap(UUID.init(uuidString:)),
                deletedAt: r[Schema.Segment.deletedAt] as? Date))
        }
    }

    private func required<T>(_ value: T?, _ field: String) throws(MappingError) -> T {
        guard let value else { throw .missingField(field) }
        return value
    }

    // MARK: - Assets

    /// An asset's record in the Attachments zone. It uploads from the device that made it.
    func assetRecord(assetID: UUID, segmentID: UUID, kind: String, byteCount: Int64, sha256: String,
                     fileURL: URL) -> CKRecord {
        let r = CKRecord(recordType: Schema.Asset.type,
                         recordID: CKRecord.ID(recordName: assetID.uuidString, zoneID: Zones.attachments))
        r[Schema.Asset.segmentID] = segmentID.uuidString
        r[Schema.Asset.kind] = kind
        r[Schema.Asset.byteCount] = byteCount
        r[Schema.Asset.sha256] = sha256
        r[Schema.Asset.file] = CKAsset(fileURL: fileURL)
        return r
    }

    // MARK: - System fields

    /// What `sync_record` keeps per record: the system fields, with the change tag.
    static func encodeSystemFields(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func decodeSystemFields(_ data: Data) throws -> CKRecord {
        let coder = try NSKeyedUnarchiver(forReadingFrom: data)
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        guard let record = CKRecord(coder: coder) else { throw MappingError.badValue("systemFields") }
        return record
    }

    // MARK: - Size

    struct Size: Sendable {
        /// The bytes of the values Knot wrote: UTF-8 for text, 8 for numbers and dates.
        var fieldBytes: Int
        /// The whole record archived locally with NSKeyedArchiver. Not what the server
        /// counts: the server's measure is not documented, and encryption adds to it.
        var archiveBytes: Int
    }

    static func size(of record: CKRecord) -> Size {
        var bytes = 0
        func count(_ value: Any?) {
            switch value {
            case let s as String: bytes += s.utf8.count
            case let d as Data: bytes += d.count
            case let ref as CKRecord.Reference: bytes += ref.recordID.recordName.utf8.count
            case is Date, is Int64, is Double, is NSNumber: bytes += 8
            case nil: break
            default: bytes += 16
            }
        }
        for key in record.allKeys() { count(record[key]) }
        for key in record.encryptedValues.allKeys() { count(record.encryptedValues[key]) }
        let archive = (try? NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true))?.count ?? -1
        return Size(fieldBytes: bytes, archiveBytes: archive)
    }
}
