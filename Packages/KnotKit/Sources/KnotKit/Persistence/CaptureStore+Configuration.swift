import Foundation
import GRDB

private struct StoredOnboardingBrowserState: Codable {
    let browserState: FolderBrowserState
    let folderCreationIntents: [VaultRelativePath]
    let dailyTemplatePath: VaultRelativePath?
}

public extension CaptureStore {
    func saveOnboardingSession(_ session: OnboardingSession) throws {
        let settings = try encoder.encode(session.workingSettings)
        let importDiff = try session.importDiff.map(encoder.encode)
        let browserState = try encoder.encode(StoredOnboardingBrowserState(
            browserState: session.browserState,
            folderCreationIntents: session.folderCreationIntents,
            dailyTemplatePath: session.dailyTemplatePath
        ))
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO onboarding_sessions
                    (id, profile_id, generation, step, working_settings_json,
                     proposed_bookmark, import_diff_json, browser_state_json, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    profile_id = excluded.profile_id,
                    generation = excluded.generation,
                    step = excluded.step,
                    working_settings_json = excluded.working_settings_json,
                    proposed_bookmark = excluded.proposed_bookmark,
                    import_diff_json = excluded.import_diff_json,
                    browser_state_json = excluded.browser_state_json,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    session.id.description, session.profileID?.description,
                    session.generation, session.step.rawValue, settings,
                    session.proposedBookmark, importDiff, browserState,
                    session.updatedAt.timeIntervalSince1970
                ]
            )
        }
    }

    func onboardingSession(id: OnboardingSessionID) throws -> OnboardingSession? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM onboarding_sessions WHERE id = ?",
                arguments: [id.description]
            ) else { return nil }
            return try decodeOnboardingSession(row)
        }
    }

    func latestOnboardingSession() throws -> OnboardingSession? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM onboarding_sessions ORDER BY updated_at DESC, id DESC LIMIT 1"
            ) else { return nil }
            return try decodeOnboardingSession(row)
        }
    }

    @discardableResult
    func finishOnboarding(
        sessionID: OnboardingSessionID,
        profileID: VaultID = VaultID(),
        displayName: String,
        resourceIdentity: Data? = nil,
        now: Date = Date()
    ) throws -> VaultID {
        try database.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM onboarding_sessions WHERE id = ?",
                arguments: [sessionID.description]
            ) else { throw ConfigurationError.sessionMissing }
            let session = try decodeOnboardingSession(row)
            guard session.step == .summary, let bookmark = session.proposedBookmark else {
                throw ConfigurationError.incompleteSession
            }
            let settingsData = try encoder.encode(session.workingSettings)
            try db.execute(
                sql: """
                INSERT INTO vault_profiles
                    (id, display_name, bookmark, resource_identity, settings_version,
                     settings_revision, settings_json, onboarding_state, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 0, ?, 'complete', ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    display_name = excluded.display_name,
                    bookmark = excluded.bookmark,
                    resource_identity = excluded.resource_identity,
                    settings_version = excluded.settings_version,
                    settings_revision = vault_profiles.settings_revision + 1,
                    settings_json = excluded.settings_json,
                    onboarding_state = 'complete',
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    profileID.description, displayName, bookmark, resourceIdentity,
                    ValidatedSettings.schemaVersion, settingsData,
                    now.timeIntervalSince1970, now.timeIntervalSince1970
                ]
            )
            try db.execute(
                sql: "DELETE FROM onboarding_sessions WHERE id = ?",
                arguments: [sessionID.description]
            )
            return profileID
        }
    }

    @discardableResult
    func applySettings(
        profileID: VaultID,
        expectedRevision: Revision,
        settings: ValidatedSettings,
        now: Date = Date()
    ) throws -> Revision {
        let data = try encoder.encode(settings)
        return try database.write { db in
            guard let current: Int64 = try Int64.fetchOne(
                db,
                sql: "SELECT settings_revision FROM vault_profiles WHERE id = ?",
                arguments: [profileID.description]
            ) else { throw CaptureStoreError.profileMissing }
            guard current == expectedRevision.rawValue else {
                throw ConfigurationError.revisionConflict(current: try Revision(current))
            }
            let next = try expectedRevision.next()
            try db.execute(
                sql: """
                UPDATE vault_profiles
                SET settings_version = ?, settings_revision = ?, settings_json = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [
                    ValidatedSettings.schemaVersion, next.rawValue, data,
                    now.timeIntervalSince1970, profileID.description
                ]
            )
            return next
        }
    }

    func resetConfiguration(
        profileID: VaultID?,
        defaults: ValidatedSettings,
        now: Date = Date()
    ) throws -> OnboardingSession {
        let session = try OnboardingSession(workingSettings: defaults, updatedAt: now)
        let settings = try encoder.encode(defaults)
        let browser = try encoder.encode(StoredOnboardingBrowserState(
            browserState: session.browserState,
            folderCreationIntents: session.folderCreationIntents,
            dailyTemplatePath: session.dailyTemplatePath
        ))
        try database.write { db in
            if let profileID {
                try db.execute(
                    sql: "UPDATE vault_profiles SET onboarding_state = 'inactive', updated_at = ? WHERE id = ?",
                    arguments: [now.timeIntervalSince1970, profileID.description]
                )
            }
            try db.execute(
                sql: """
                INSERT INTO onboarding_sessions
                    (id, profile_id, generation, step, working_settings_json,
                     proposed_bookmark, import_diff_json, browser_state_json, updated_at)
                VALUES (?, NULL, 0, 'vault', ?, NULL, NULL, ?, ?)
                """,
                arguments: [session.id.description, settings, browser, now.timeIntervalSince1970]
            )
        }
        return session
    }

    func activeProfile() throws -> VaultProfileRecord? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM vault_profiles WHERE onboarding_state = 'complete' ORDER BY updated_at DESC LIMIT 1"
            ) else { return nil }
            return try decodeProfile(row)
        }
    }

    func discardDraft(id: DraftID) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE drafts SET state = 'discarded' WHERE id = ?", arguments: [id.description])
        }
    }

    private func decodeOnboardingSession(_ row: Row) throws -> OnboardingSession {
        guard let uuid = UUID(uuidString: row["id"]) else { throw CaptureStoreError.corruptRecord }
        let profileString: String? = row["profile_id"]
        guard let step = OnboardingStep(rawValue: row["step"]) else { throw CaptureStoreError.corruptRecord }
        let diffData: Data? = row["import_diff_json"]
        let browserData: Data? = row["browser_state_json"]
        let settings: ValidatedSettings = try decoder.decode(ValidatedSettings.self, from: row["working_settings_json"])
        let persistedBrowser: StoredOnboardingBrowserState
        if let browserData {
            if let current = try? decoder.decode(StoredOnboardingBrowserState.self, from: browserData) {
                persistedBrowser = current
            } else {
                persistedBrowser = StoredOnboardingBrowserState(
                    browserState: try decoder.decode(FolderBrowserState.self, from: browserData),
                    folderCreationIntents: [],
                    dailyTemplatePath: nil
                )
            }
        } else {
            persistedBrowser = StoredOnboardingBrowserState(
                browserState: FolderBrowserState(), folderCreationIntents: [], dailyTemplatePath: nil
            )
        }
        let diff = try diffData.map { try decoder.decode(ConfigDiff.self, from: $0) }
        return try OnboardingSession(
            id: OnboardingSessionID(rawValue: uuid),
            profileID: profileString.flatMap(UUID.init(uuidString:)).map(VaultID.init(rawValue:)),
            generation: row["generation"],
            step: step,
            workingSettings: settings,
            proposedBookmark: row["proposed_bookmark"],
            importDiff: diff,
            browserState: persistedBrowser.browserState,
            folderCreationIntents: persistedBrowser.folderCreationIntents,
            dailyTemplatePath: persistedBrowser.dailyTemplatePath,
            updatedAt: Date(timeIntervalSince1970: row["updated_at"])
        )
    }
}
