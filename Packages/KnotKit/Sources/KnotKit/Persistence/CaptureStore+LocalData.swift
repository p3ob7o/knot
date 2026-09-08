import Foundation
import GRDB

public extension CaptureStore {
    @discardableResult
    func eraseLocalDrafts() throws -> Int {
        let result: (count: Int, assetPaths: [String]) = try database.write { db in
            let draftIDs = try String.fetchAll(
                db,
                sql: """
                SELECT id FROM drafts
                WHERE state IN ('active','parked')
                  AND NOT EXISTS (SELECT 1 FROM captures WHERE captures.draft_id = drafts.id)
                """
            )
            guard !draftIDs.isEmpty else { return (0, []) }

            let placeholders = Array(repeating: "?", count: draftIDs.count).joined(separator: ",")
            let candidatePaths = try String.fetchAll(
                db,
                sql: """
                SELECT DISTINCT assets.local_relative_path
                FROM assets
                JOIN draft_assets ON draft_assets.asset_id = assets.id
                WHERE draft_assets.owner_id IN (\(placeholders))
                  AND NOT EXISTS (
                    SELECT 1 FROM capture_assets
                    WHERE capture_assets.asset_id = assets.id
                  )
                  AND NOT EXISTS (
                    SELECT 1 FROM draft_assets AS retained_links
                    WHERE retained_links.asset_id = assets.id
                      AND retained_links.owner_id NOT IN (\(placeholders))
                  )
                """,
                arguments: StatementArguments(draftIDs + draftIDs)
            )
            try db.execute(
                sql: "DELETE FROM drafts WHERE id IN (\(placeholders))",
                arguments: StatementArguments(draftIDs)
            )
            try db.execute(
                sql: """
                DELETE FROM assets
                WHERE NOT EXISTS (SELECT 1 FROM draft_assets WHERE draft_assets.asset_id = assets.id)
                  AND NOT EXISTS (SELECT 1 FROM capture_assets WHERE capture_assets.asset_id = assets.id)
                """
            )
            return (draftIDs.count, candidatePaths)
        }

        for relativePath in result.assetPaths {
            let candidate = rootDirectory.appending(path: relativePath)
            guard candidate.standardizedFileURL.path.hasPrefix(rootDirectory.standardizedFileURL.path + "/") else {
                continue
            }
            try? FileManager.default.removeItem(at: candidate)
            try? FileManager.default.removeItem(at: candidate.deletingLastPathComponent())
        }
        return result.count
    }
}
