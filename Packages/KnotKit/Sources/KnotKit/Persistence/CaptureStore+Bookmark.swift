import Foundation
import GRDB

public extension CaptureStore {
    func updateBookmark(profileID: VaultID, bookmark: Data, now: Date = Date()) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE vault_profiles SET bookmark = ?, updated_at = ? WHERE id = ?",
                arguments: [bookmark, now.timeIntervalSince1970, profileID.description]
            )
            guard db.changesCount == 1 else { throw CaptureStoreError.profileMissing }
        }
    }
}
