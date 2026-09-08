import GRDB

public extension CaptureStore {
    func recoverableDrafts() throws -> [DraftCheckpoint] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM drafts
                WHERE state IN ('active','parked')
                ORDER BY updated_at DESC, id DESC
                """
            )
            return try rows.map(decodeDraft)
        }
    }
}
