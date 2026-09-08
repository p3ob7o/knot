import CryptoKit
import Foundation

final class RichCheckpointTransferStore {
    enum TransferError: Error { case invalid }
    private struct Transfer {
        let baseRevision: Int64
        let nextRevision: Int64
        let totalBytes: Int
        let sha256: String
        let expiresAt: ContinuousClock.Instant
        var nextSequence = 0
        var data = Data()
    }
    private var transfers: [UUID: Transfer] = [:]
    private let maximumBytes = 24 * 1_024 * 1_024
    private let maximumChunk = 176 * 1_024

    func accept(type: String, payload: [String: Any]) throws -> [String: Any]? {
        cleanup()
        guard let idText = payload["transferID"] as? String, let id = UUID(uuidString: idText) else {
            throw TransferError.invalid
        }
        switch type {
        case "checkpointBegin":
            guard transfers.isEmpty,
                  let base = (payload["baseRevision"] as? NSNumber)?.int64Value,
                  let next = (payload["nextRevision"] as? NSNumber)?.int64Value, next == base + 1,
                  let total = (payload["totalBytes"] as? NSNumber)?.intValue,
                  total > 0, total <= maximumBytes,
                  let hash = payload["sha256"] as? String, hash.count == 64 else {
                throw TransferError.invalid
            }
            transfers[id] = Transfer(
                baseRevision: base, nextRevision: next, totalBytes: total,
                sha256: hash.lowercased(), expiresAt: .now + .seconds(10)
            )
            return nil
        case "checkpointChunk":
            guard var transfer = transfers[id], transfer.expiresAt > .now,
                  let sequence = payload["sequence"] as? Int, sequence == transfer.nextSequence,
                  let encoded = payload["dataBase64"] as? String, encoded.utf8.count <= 240 * 1_024,
                  let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= maximumChunk,
                  transfer.data.count + bytes.count <= transfer.totalBytes else {
                transfers.removeValue(forKey: id)
                throw TransferError.invalid
            }
            transfer.data.append(bytes)
            transfer.nextSequence += 1
            transfers[id] = transfer
            return nil
        case "checkpointEnd":
            guard let transfer = transfers.removeValue(forKey: id), transfer.expiresAt > .now,
                  transfer.data.count == transfer.totalBytes,
                  payload["sha256"] as? String == transfer.sha256,
                  Self.hash(transfer.data) == transfer.sha256,
                  let object = try JSONSerialization.jsonObject(with: transfer.data) as? [String: Any],
                  (object["baseRevision"] as? NSNumber)?.int64Value == transfer.baseRevision,
                  (object["nextRevision"] as? NSNumber)?.int64Value == transfer.nextRevision else {
                throw TransferError.invalid
            }
            return object
        default:
            throw TransferError.invalid
        }
    }

    func removeAll() { transfers.removeAll() }

    private func cleanup() { transfers = transfers.filter { $0.value.expiresAt > .now } }
    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
