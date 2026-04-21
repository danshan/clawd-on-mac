import Foundation
import SQLite3

// MARK: - Record types

struct SkillRecord: Codable {
    let id: String
    var name: String
    var description: String?
    var sourceType: String          // local | git | skillssh
    var sourceRef: String?
    var sourceRefResolved: String?
    var sourceSubpath: String?
    var sourceBranch: String?
    var sourceRevision: String?
    var remoteRevision: String?
    var centralPath: String
    var contentHash: String?
    var enabled: Bool
    var status: String              // ok | error
    var updateStatus: String        // unknown | up_to_date | update_available | checking
    var lastCheckedAt: Int64?
    var lastCheckError: String?
    var createdAt: Int64
    var updatedAt: Int64
}

struct SkillTargetRecord: Codable {
    let skillId: String
    let tool: String
    var targetPath: String
    var mode: String                // symlink | copy
    var status: String?
    var syncedAt: Int64?
    var lastError: String?
}

struct ScenarioRecord: Codable {
    let id: String
    var name: String
    var description: String?
    var icon: String?
    var sortOrder: Int32
    var createdAt: Int64
    var updatedAt: Int64
}

struct ScenarioSkillToolToggle: Codable {
    let scenarioId: String
    let skillId: String
    let tool: String
    var enabled: Bool
}

struct ProjectRecord: Codable {
    let id: String
    var name: String
    var path: String
    var workspaceType: String       // project | linked
    var linkedAgentKey: String?
    var linkedAgentName: String?
    var disabledPath: String?
    var sortOrder: Int32
    var createdAt: Int64
    var updatedAt: Int64
}

struct DiscoveredSkillRecord: Codable {
    let id: String
    let tool: String
    let foundPath: String
    var nameGuess: String?
    var fingerprint: String?
    let foundAt: Int64
    var importedSkillId: String?
}

// MARK: - Database

final class SkillDatabase {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.clawd.skilldb", qos: .utility)

    init(path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var dbPtr: OpaquePointer?
        guard sqlite3_open(path, &dbPtr) == SQLITE_OK else {
            let msg = dbPtr.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(dbPtr)
            throw SkillDBError.openFailed(msg)
        }
        self.db = dbPtr
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA busy_timeout=5000")
        try runMigrations()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Transaction support

    /// Execute a block within a database transaction. Rolls back on error.
    func transaction<T>(_ block: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try block()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Migration

    private func runMigrations() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS skills (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                description TEXT,
                source_type TEXT NOT NULL DEFAULT 'local',
                source_ref TEXT,
                source_ref_resolved TEXT,
                source_subpath TEXT,
                source_branch TEXT,
                source_revision TEXT,
                remote_revision TEXT,
                central_path TEXT NOT NULL UNIQUE,
                content_hash TEXT,
                enabled INTEGER NOT NULL DEFAULT 1,
                status TEXT NOT NULL DEFAULT 'ok',
                update_status TEXT NOT NULL DEFAULT 'unknown',
                last_checked_at INTEGER,
                last_check_error TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_skills_name ON skills(name);

            CREATE TABLE IF NOT EXISTS skill_targets (
                skill_id TEXT NOT NULL,
                tool TEXT NOT NULL,
                target_path TEXT NOT NULL,
                mode TEXT NOT NULL DEFAULT 'symlink',
                status TEXT DEFAULT 'ok',
                synced_at INTEGER,
                last_error TEXT,
                PRIMARY KEY (skill_id, tool),
                FOREIGN KEY (skill_id) REFERENCES skills(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS skill_tags (
                skill_id TEXT NOT NULL,
                tag TEXT NOT NULL,
                PRIMARY KEY (skill_id, tag),
                FOREIGN KEY (skill_id) REFERENCES skills(id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS idx_skill_tags_tag ON skill_tags(tag);

            CREATE TABLE IF NOT EXISTS discovered_skills (
                id TEXT PRIMARY KEY,
                tool TEXT NOT NULL,
                found_path TEXT NOT NULL,
                name_guess TEXT,
                fingerprint TEXT,
                found_at INTEGER NOT NULL,
                imported_skill_id TEXT,
                FOREIGN KEY (imported_skill_id) REFERENCES skills(id) ON DELETE SET NULL
            );

            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT
            );

            CREATE TABLE IF NOT EXISTS scenarios (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                description TEXT,
                icon TEXT,
                sort_order INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS scenario_skills (
                scenario_id TEXT NOT NULL,
                skill_id TEXT NOT NULL,
                sort_order INTEGER NOT NULL DEFAULT 0,
                added_at INTEGER NOT NULL,
                PRIMARY KEY (scenario_id, skill_id),
                FOREIGN KEY (scenario_id) REFERENCES scenarios(id) ON DELETE CASCADE,
                FOREIGN KEY (skill_id) REFERENCES skills(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS scenario_skill_tools (
                scenario_id TEXT NOT NULL,
                skill_id TEXT NOT NULL,
                tool TEXT NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 1,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (scenario_id, skill_id, tool),
                FOREIGN KEY (scenario_id) REFERENCES scenarios(id) ON DELETE CASCADE,
                FOREIGN KEY (skill_id) REFERENCES skills(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS active_scenario (
                key TEXT PRIMARY KEY DEFAULT 'current',
                scenario_id TEXT,
                FOREIGN KEY (scenario_id) REFERENCES scenarios(id) ON DELETE SET NULL
            );

            CREATE TABLE IF NOT EXISTS projects (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                path TEXT NOT NULL UNIQUE,
                workspace_type TEXT NOT NULL DEFAULT 'project',
                linked_agent_key TEXT,
                linked_agent_name TEXT,
                disabled_path TEXT,
                sort_order INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_projects_path ON projects(path);
        """)
    }

    // MARK: - Skills CRUD

    func insertSkill(_ skill: SkillRecord) throws {
        try queue.sync {
            try execute(
                """
                INSERT INTO skills (
                    id, name, description, source_type, source_ref, source_ref_resolved,
                    source_subpath, source_branch, source_revision, remote_revision,
                    central_path, content_hash, enabled, status, update_status,
                    last_checked_at, last_check_error, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                params: [
                    .text(skill.id), .text(skill.name), .textOrNull(skill.description),
                    .text(skill.sourceType), .textOrNull(skill.sourceRef),
                    .textOrNull(skill.sourceRefResolved), .textOrNull(skill.sourceSubpath),
                    .textOrNull(skill.sourceBranch), .textOrNull(skill.sourceRevision),
                    .textOrNull(skill.remoteRevision), .text(skill.centralPath),
                    .textOrNull(skill.contentHash), .int(skill.enabled ? 1 : 0),
                    .text(skill.status), .text(skill.updateStatus),
                    .int64OrNull(skill.lastCheckedAt), .textOrNull(skill.lastCheckError),
                    .int64(skill.createdAt), .int64(skill.updatedAt),
                ]
            )
        }
    }

    func getAllSkills() throws -> [SkillRecord] {
        try queue.sync {
            try query("SELECT * FROM skills ORDER BY name", mapper: mapSkillRow)
        }
    }

    func getSkill(id: String) throws -> SkillRecord? {
        try queue.sync {
            try query("SELECT * FROM skills WHERE id = ?",
                      params: [.text(id)], mapper: mapSkillRow).first
        }
    }

    func getSkillByCentralPath(_ centralPath: String) throws -> SkillRecord? {
        try queue.sync {
            try query("SELECT * FROM skills WHERE central_path = ?",
                      params: [.text(centralPath)], mapper: mapSkillRow).first
        }
    }

    func updateSkillContentHash(id: String, contentHash: String?) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try queue.sync {
            try execute("UPDATE skills SET content_hash = ?, updated_at = ? WHERE id = ?",
                        params: [.textOrNull(contentHash), .int64(now), .text(id)])
        }
    }

    func updateSkillCheckState(id: String, remoteRevision: String?, updateStatus: String, lastCheckError: String?) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try queue.sync {
            try execute(
                "UPDATE skills SET remote_revision = ?, update_status = ?, last_checked_at = ?, last_check_error = ? WHERE id = ?",
                params: [.textOrNull(remoteRevision), .text(updateStatus), .int64(now),
                         .textOrNull(lastCheckError), .text(id)]
            )
        }
    }

    func updateSkillAfterInstall(
        id: String, name: String, description: String?,
        sourceRevision: String?, remoteRevision: String?,
        contentHash: String?, updateStatus: String
    ) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try queue.sync {
            try execute(
                """
                UPDATE skills SET name = ?, description = ?, source_revision = ?, remote_revision = ?,
                    content_hash = ?, updated_at = ?, update_status = ?, last_checked_at = ?, last_check_error = NULL
                WHERE id = ?
                """,
                params: [.text(name), .textOrNull(description), .textOrNull(sourceRevision),
                         .textOrNull(remoteRevision), .textOrNull(contentHash),
                         .int64(now), .text(updateStatus), .int64(now), .text(id)]
            )
        }
    }

    func deleteSkill(id: String) throws {
        try queue.sync {
            try execute("DELETE FROM skills WHERE id = ?", params: [.text(id)])
        }
    }

    func updateSkillEnabled(id: String, enabled: Bool) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try queue.sync {
            try execute("UPDATE skills SET enabled = ?, updated_at = ? WHERE id = ?",
                        params: [.int64(enabled ? 1 : 0), .int64(now), .text(id)])
        }
    }

    func updateSkillDescription(id: String, name: String, description: String?) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try queue.sync {
            try execute("UPDATE skills SET name = ?, description = ?, updated_at = ? WHERE id = ?",
                        params: [.text(name), .textOrNull(description), .int64(now), .text(id)])
        }
    }

    func updateSourceRef(id: String, sourceRef: String?) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try queue.sync {
            try execute(
                "UPDATE skills SET source_ref = ?, updated_at = ? WHERE id = ?",
                params: [.textOrNull(sourceRef), .int64(now), .text(id)]
            )
        }
    }

    // MARK: - Targets

    func insertTarget(_ target: SkillTargetRecord) throws {
        try queue.sync {
            try execute(
                """
                INSERT OR REPLACE INTO skill_targets (skill_id, tool, target_path, mode, status, synced_at, last_error)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                params: [
                    .text(target.skillId), .text(target.tool), .text(target.targetPath),
                    .text(target.mode), .textOrNull(target.status),
                    .int64OrNull(target.syncedAt), .textOrNull(target.lastError),
                ]
            )
        }
    }

    func getTargets(forSkill skillId: String) throws -> [SkillTargetRecord] {
        try queue.sync {
            try query(
                "SELECT skill_id, tool, target_path, mode, status, synced_at, last_error FROM skill_targets WHERE skill_id = ?",
                params: [.text(skillId)], mapper: mapTargetRow
            )
        }
    }

    func getAllTargets() throws -> [SkillTargetRecord] {
        try queue.sync {
            try query(
                "SELECT skill_id, tool, target_path, mode, status, synced_at, last_error FROM skill_targets",
                mapper: mapTargetRow
            )
        }
    }

    func deleteTarget(skillId: String, tool: String) throws {
        try queue.sync {
            try execute("DELETE FROM skill_targets WHERE skill_id = ? AND tool = ?",
                        params: [.text(skillId), .text(tool)])
        }
    }

    func deleteAllTargets(forSkill skillId: String) throws {
        try queue.sync {
            try execute("DELETE FROM skill_targets WHERE skill_id = ?", params: [.text(skillId)])
        }
    }

    // MARK: - Tags

    func setTags(forSkill skillId: String, tags: [String]) throws {
        try queue.sync {
            try execute("DELETE FROM skill_tags WHERE skill_id = ?", params: [.text(skillId)])
            for tag in tags {
                try execute("INSERT INTO skill_tags (skill_id, tag) VALUES (?, ?)",
                            params: [.text(skillId), .text(tag)])
            }
        }
    }

    func getTags(forSkill skillId: String) throws -> [String] {
        try queue.sync {
            try query("SELECT tag FROM skill_tags WHERE skill_id = ?",
                      params: [.text(skillId)]) { stmt in
                String(cString: sqlite3_column_text(stmt, 0))
            }
        }
    }

    func getAllTags() throws -> [String] {
        try queue.sync {
            try query("SELECT DISTINCT tag FROM skill_tags ORDER BY tag", params: []) { stmt in
                String(cString: sqlite3_column_text(stmt, 0))
            }
        }
    }

    // MARK: - Discovered skills

    func insertDiscovered(_ record: DiscoveredSkillRecord) throws {
        try queue.sync {
            try execute(
                """
                INSERT OR REPLACE INTO discovered_skills (id, tool, found_path, name_guess, fingerprint, found_at, imported_skill_id)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                params: [
                    .text(record.id), .text(record.tool), .text(record.foundPath),
                    .textOrNull(record.nameGuess), .textOrNull(record.fingerprint),
                    .int64(record.foundAt), .textOrNull(record.importedSkillId),
                ]
            )
        }
    }

    func getAllDiscovered() throws -> [DiscoveredSkillRecord] {
        try queue.sync {
            try query(
                "SELECT id, tool, found_path, name_guess, fingerprint, found_at, imported_skill_id FROM discovered_skills",
                mapper: mapDiscoveredRow
            )
        }
    }

    func clearDiscovered() throws {
        try queue.sync { try execute("DELETE FROM discovered_skills") }
    }

    // MARK: - Scenarios

    func insertScenario(_ scenario: ScenarioRecord) throws {
        try queue.sync {
            try execute(
                """
                INSERT INTO scenarios (id, name, description, icon, sort_order, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                params: [
                    .text(scenario.id), .text(scenario.name), .textOrNull(scenario.description),
                    .textOrNull(scenario.icon), .int(scenario.sortOrder),
                    .int64(scenario.createdAt), .int64(scenario.updatedAt),
                ]
            )
        }
    }

    func getAllScenarios() throws -> [ScenarioRecord] {
        try queue.sync {
            try query(
                "SELECT id, name, description, icon, sort_order, created_at, updated_at FROM scenarios ORDER BY sort_order, name",
                mapper: mapScenarioRow
            )
        }
    }

    func getScenario(id: String) throws -> ScenarioRecord? {
        try queue.sync {
            try query(
                "SELECT id, name, description, icon, sort_order, created_at, updated_at FROM scenarios WHERE id = ?",
                params: [.text(id)], mapper: mapScenarioRow
            ).first
        }
    }

    func updateScenario(id: String, name: String, description: String?, icon: String?) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try queue.sync {
            try execute(
                "UPDATE scenarios SET name = ?, description = ?, icon = ?, updated_at = ? WHERE id = ?",
                params: [.text(name), .textOrNull(description), .textOrNull(icon), .int64(now), .text(id)]
            )
        }
    }

    func deleteScenario(id: String) throws {
        try queue.sync {
            try execute("DELETE FROM scenarios WHERE id = ?", params: [.text(id)])
        }
    }

    func reorderScenarios(ids: [String]) throws {
        try queue.sync {
            for (i, id) in ids.enumerated() {
                try execute("UPDATE scenarios SET sort_order = ? WHERE id = ?",
                            params: [.int(Int32(i)), .text(id)])
            }
        }
    }

    func countSkillsForScenario(id: String) throws -> Int {
        try queue.sync {
            let rows = try query("SELECT COUNT(*) FROM scenario_skills WHERE scenario_id = ?",
                                 params: [.text(id)]) { stmt in Int(sqlite3_column_int(stmt, 0)) }
            return rows.first ?? 0
        }
    }

    // MARK: Scenario-Skill relations

    func addSkillToScenario(scenarioId: String, skillId: String) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try queue.sync {
            let maxOrder = try query(
                "SELECT COALESCE(MAX(sort_order), -1) FROM scenario_skills WHERE scenario_id = ?",
                params: [.text(scenarioId)]
            ) { stmt in Int32(sqlite3_column_int(stmt, 0)) }.first ?? -1

            try execute(
                "INSERT OR IGNORE INTO scenario_skills (scenario_id, skill_id, sort_order, added_at) VALUES (?, ?, ?, ?)",
                params: [.text(scenarioId), .text(skillId), .int(maxOrder + 1), .int64(now)]
            )
        }
    }

    func removeSkillFromScenario(scenarioId: String, skillId: String) throws {
        try queue.sync {
            try execute("DELETE FROM scenario_skills WHERE scenario_id = ? AND skill_id = ?",
                        params: [.text(scenarioId), .text(skillId)])
            try execute("DELETE FROM scenario_skill_tools WHERE scenario_id = ? AND skill_id = ?",
                        params: [.text(scenarioId), .text(skillId)])
        }
    }

    func getSkillIdsForScenario(id: String) throws -> [String] {
        try queue.sync {
            try query(
                "SELECT skill_id FROM scenario_skills WHERE scenario_id = ? ORDER BY sort_order",
                params: [.text(id)]
            ) { stmt in String(cString: sqlite3_column_text(stmt, 0)) }
        }
    }

    func getSkillsForScenario(id: String) throws -> [SkillRecord] {
        try queue.sync {
            try query(
                """
                SELECT s.* FROM skills s
                JOIN scenario_skills ss ON s.id = ss.skill_id
                WHERE ss.scenario_id = ?
                ORDER BY ss.sort_order
                """,
                params: [.text(id)], mapper: mapSkillRow
            )
        }
    }

    func reorderScenarioSkills(scenarioId: String, skillIds: [String]) throws {
        try queue.sync {
            for (i, skillId) in skillIds.enumerated() {
                try execute(
                    "UPDATE scenario_skills SET sort_order = ? WHERE scenario_id = ? AND skill_id = ?",
                    params: [.int(Int32(i)), .text(scenarioId), .text(skillId)]
                )
            }
        }
    }

    func getScenariosForSkill(skillId: String) throws -> [String] {
        try queue.sync {
            try query(
                "SELECT scenario_id FROM scenario_skills WHERE skill_id = ?",
                params: [.text(skillId)]
            ) { stmt in String(cString: sqlite3_column_text(stmt, 0)) }
        }
    }

    // MARK: Scenario-Skill-Tool toggles

    func ensureScenarioSkillToolDefaults(scenarioId: String, skillId: String, tools: [String]) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try queue.sync {
            for tool in tools {
                try execute(
                    "INSERT OR IGNORE INTO scenario_skill_tools (scenario_id, skill_id, tool, enabled, updated_at) VALUES (?, ?, ?, 1, ?)",
                    params: [.text(scenarioId), .text(skillId), .text(tool), .int64(now)]
                )
            }
        }
    }

    func setScenarioSkillToolEnabled(scenarioId: String, skillId: String, tool: String, enabled: Bool) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try queue.sync {
            try execute(
                "INSERT OR REPLACE INTO scenario_skill_tools (scenario_id, skill_id, tool, enabled, updated_at) VALUES (?, ?, ?, ?, ?)",
                params: [.text(scenarioId), .text(skillId), .text(tool), .int(enabled ? 1 : 0), .int64(now)]
            )
        }
    }

    func getScenarioSkillToolToggles(scenarioId: String, skillId: String) throws -> [ScenarioSkillToolToggle] {
        try queue.sync {
            try query(
                "SELECT scenario_id, skill_id, tool, enabled FROM scenario_skill_tools WHERE scenario_id = ? AND skill_id = ?",
                params: [.text(scenarioId), .text(skillId)]
            ) { stmt in
                ScenarioSkillToolToggle(
                    scenarioId: String(cString: sqlite3_column_text(stmt, 0)),
                    skillId: String(cString: sqlite3_column_text(stmt, 1)),
                    tool: String(cString: sqlite3_column_text(stmt, 2)),
                    enabled: sqlite3_column_int(stmt, 3) != 0
                )
            }
        }
    }

    func getEnabledToolsForScenarioSkill(scenarioId: String, skillId: String) throws -> [String] {
        try queue.sync {
            try query(
                "SELECT tool FROM scenario_skill_tools WHERE scenario_id = ? AND skill_id = ? AND enabled = 1",
                params: [.text(scenarioId), .text(skillId)]
            ) { stmt in String(cString: sqlite3_column_text(stmt, 0)) }
        }
    }

    // MARK: Active scenario

    func getActiveScenarioId() throws -> String? {
        try queue.sync {
            try query("SELECT scenario_id FROM active_scenario WHERE key = 'current'",
                      params: []) { stmt in
                sqlite3_column_type(stmt, 0) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 0))
            }.first ?? nil
        }
    }

    func setActiveScenario(id: String?) throws {
        try queue.sync {
            if let id = id {
                try execute(
                    "INSERT OR REPLACE INTO active_scenario (key, scenario_id) VALUES ('current', ?)",
                    params: [.text(id)]
                )
            } else {
                try execute("DELETE FROM active_scenario WHERE key = 'current'")
            }
        }
    }

    private func mapScenarioRow(_ stmt: OpaquePointer?) -> ScenarioRecord {
        ScenarioRecord(
            id: col(stmt, 0), name: col(stmt, 1), description: colOpt(stmt, 2),
            icon: colOpt(stmt, 3), sortOrder: sqlite3_column_int(stmt, 4),
            createdAt: sqlite3_column_int64(stmt, 5), updatedAt: sqlite3_column_int64(stmt, 6)
        )
    }

    // MARK: - Settings KV

    func getSetting(_ key: String) throws -> String? {
        try queue.sync {
            try query("SELECT value FROM settings WHERE key = ?",
                      params: [.text(key)]) { stmt in
                sqlite3_column_text(stmt, 0).map { String(cString: $0) }
            }.first ?? nil
        }
    }

    func setSetting(_ key: String, value: String?) throws {
        try queue.sync {
            if let value = value {
                try execute("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                            params: [.text(key), .text(value)])
            } else {
                try execute("DELETE FROM settings WHERE key = ?", params: [.text(key)])
            }
        }
    }

    // MARK: - Projects CRUD

    func insertProject(_ project: ProjectRecord) throws {
        try queue.sync {
            try execute("""
                INSERT INTO projects (
                    id, name, path, workspace_type, linked_agent_key, linked_agent_name,
                    disabled_path, sort_order, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                params: [
                    .text(project.id), .text(project.name), .text(project.path),
                    .text(project.workspaceType), .textOrNull(project.linkedAgentKey),
                    .textOrNull(project.linkedAgentName), .textOrNull(project.disabledPath),
                    .int(project.sortOrder), .int64(project.createdAt), .int64(project.updatedAt),
                ])
        }
    }

    func getAllProjects() throws -> [ProjectRecord] {
        try queue.sync {
            try query("SELECT * FROM projects ORDER BY sort_order, name", mapper: mapProjectRow)
        }
    }

    func getProject(id: String) throws -> ProjectRecord? {
        try queue.sync {
            try query("SELECT * FROM projects WHERE id = ?",
                      params: [.text(id)], mapper: mapProjectRow).first
        }
    }

    func getProjectByPath(_ path: String) throws -> ProjectRecord? {
        try queue.sync {
            try query("SELECT * FROM projects WHERE path = ?",
                      params: [.text(path)], mapper: mapProjectRow).first
        }
    }

    func updateProject(id: String, name: String) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try queue.sync {
            try execute("UPDATE projects SET name = ?, updated_at = ? WHERE id = ?",
                        params: [.text(name), .int64(now), .text(id)])
        }
    }

    func deleteProject(id: String) throws {
        try queue.sync {
            try execute("DELETE FROM projects WHERE id = ?", params: [.text(id)])
        }
    }

    func reorderProjects(ids: [String]) throws {
        try queue.sync {
            for (i, id) in ids.enumerated() {
                try execute("UPDATE projects SET sort_order = ? WHERE id = ?",
                            params: [.int(Int32(i)), .text(id)])
            }
        }
    }

    func getProjectCount() throws -> Int {
        try queue.sync {
            let rows = try query("SELECT COUNT(*) FROM projects") { stmt in
                sqlite3_column_int(stmt, 0)
            }
            return Int(rows.first ?? 0)
        }
    }

    // MARK: - Row mappers

    private func mapSkillRow(_ stmt: OpaquePointer?) -> SkillRecord {
        SkillRecord(
            id: col(stmt, 0), name: col(stmt, 1), description: colOpt(stmt, 2),
            sourceType: col(stmt, 3), sourceRef: colOpt(stmt, 4),
            sourceRefResolved: colOpt(stmt, 5), sourceSubpath: colOpt(stmt, 6),
            sourceBranch: colOpt(stmt, 7), sourceRevision: colOpt(stmt, 8),
            remoteRevision: colOpt(stmt, 9), centralPath: col(stmt, 10),
            contentHash: colOpt(stmt, 11), enabled: sqlite3_column_int(stmt, 12) != 0,
            status: col(stmt, 13), updateStatus: col(stmt, 14),
            lastCheckedAt: colInt64Opt(stmt, 15), lastCheckError: colOpt(stmt, 16),
            createdAt: sqlite3_column_int64(stmt, 17), updatedAt: sqlite3_column_int64(stmt, 18)
        )
    }

    private func mapTargetRow(_ stmt: OpaquePointer?) -> SkillTargetRecord {
        SkillTargetRecord(
            skillId: col(stmt, 0), tool: col(stmt, 1), targetPath: col(stmt, 2),
            mode: col(stmt, 3), status: colOpt(stmt, 4),
            syncedAt: colInt64Opt(stmt, 5), lastError: colOpt(stmt, 6)
        )
    }

    private func mapDiscoveredRow(_ stmt: OpaquePointer?) -> DiscoveredSkillRecord {
        DiscoveredSkillRecord(
            id: col(stmt, 0), tool: col(stmt, 1), foundPath: col(stmt, 2),
            nameGuess: colOpt(stmt, 3), fingerprint: colOpt(stmt, 4),
            foundAt: sqlite3_column_int64(stmt, 5), importedSkillId: colOpt(stmt, 6)
        )
    }

    private func mapProjectRow(_ stmt: OpaquePointer?) -> ProjectRecord {
        ProjectRecord(
            id: col(stmt, 0), name: col(stmt, 1), path: col(stmt, 2),
            workspaceType: col(stmt, 3), linkedAgentKey: colOpt(stmt, 4),
            linkedAgentName: colOpt(stmt, 5), disabledPath: colOpt(stmt, 6),
            sortOrder: sqlite3_column_int(stmt, 7),
            createdAt: sqlite3_column_int64(stmt, 8), updatedAt: sqlite3_column_int64(stmt, 9)
        )
    }

    // MARK: - SQLite helpers

    private func col(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        sqlite3_column_text(stmt, idx).map { String(cString: $0) } ?? ""
    }

    private func colOpt(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
        return sqlite3_column_text(stmt, idx).map { String(cString: $0) }
    }

    private func colInt64Opt(_ stmt: OpaquePointer?, _ idx: Int32) -> Int64? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(stmt, idx)
    }

    private enum Param {
        case text(String)
        case textOrNull(String?)
        case int(Int32)
        case int64(Int64)
        case int64OrNull(Int64?)
    }

    private func bind(_ stmt: OpaquePointer?, params: [Param]) {
        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            switch param {
            case .text(let v):
                sqlite3_bind_text(stmt, idx, (v as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .textOrNull(let v):
                if let v = v {
                    sqlite3_bind_text(stmt, idx, (v as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                } else {
                    sqlite3_bind_null(stmt, idx)
                }
            case .int(let v):
                sqlite3_bind_int(stmt, idx, v)
            case .int64(let v):
                sqlite3_bind_int64(stmt, idx, v)
            case .int64OrNull(let v):
                if let v = v {
                    sqlite3_bind_int64(stmt, idx, v)
                } else {
                    sqlite3_bind_null(stmt, idx)
                }
            }
        }
    }

    @discardableResult
    private func execute(_ sql: String, params: [Param] = []) throws -> Int32 {
        if params.isEmpty {
            var errmsg: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, sql, nil, nil, &errmsg)
            if rc != SQLITE_OK {
                let msg = errmsg.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(errmsg)
                throw SkillDBError.executeFailed(msg)
            }
            return rc
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SkillDBError.executeFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params: params)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SkillDBError.executeFailed(String(cString: sqlite3_errmsg(db)))
        }
        return rc
    }

    private func query<T>(_ sql: String, params: [Param] = [], mapper: (OpaquePointer?) -> T) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SkillDBError.executeFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params: params)
        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(mapper(stmt))
        }
        return results
    }
}

// MARK: - Errors

enum SkillDBError: LocalizedError {
    case openFailed(String)
    case executeFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "Failed to open skills database: \(msg)"
        case .executeFailed(let msg): return "SQL execution failed: \(msg)"
        }
    }
}
