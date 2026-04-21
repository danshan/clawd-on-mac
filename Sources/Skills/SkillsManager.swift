import Foundation

/// Unified facade for all skills management operations.
/// Coordinates database, installer, scanner, sync engine, and marketplace.
final class SkillsManager {

    let database: SkillDatabase
    let installer: SkillInstaller
    let scanner: SkillScanner
    let syncEngine: SyncEngine
    let marketplace: SkillsMarketplace
    let gitBackup: GitBackup
    let projectManager: ProjectManager

    private let centralSkillsDir: URL
    private let installQueue = DispatchQueue(label: "com.clawd.skills.install")
    private var installsInFlight: Set<String> = []
    private let installLock = NSLock()

    init() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let clawdDir = home.appendingPathComponent(".clawd")
        centralSkillsDir = clawdDir.appendingPathComponent("skills")

        try FileManager.default.createDirectory(at: centralSkillsDir, withIntermediateDirectories: true)

        database = try SkillDatabase(path: clawdDir.appendingPathComponent("skills.db").path)
        installer = SkillInstaller()
        scanner = SkillScanner()
        syncEngine = SyncEngine()
        marketplace = SkillsMarketplace(db: database)
        gitBackup = GitBackup(skillsDir: centralSkillsDir)
        projectManager = ProjectManager(db: database)
    }

    // MARK: - List skills

    struct ManagedSkillDTO: Codable {
        let id: String
        let name: String
        let description: String?
        let sourceType: String
        let sourceRef: String?
        let centralPath: String
        let enabled: Bool
        let status: String
        let updateStatus: String
        let targets: [SkillTargetRecord]
        let tags: [String]
        let createdAt: Int64
        let updatedAt: Int64
    }

    func listSkills() throws -> [ManagedSkillDTO] {
        let skills = try database.getAllSkills()
        return try skills.map { skill in
            let targets = try database.getTargets(forSkill: skill.id)
            let tags = try database.getTags(forSkill: skill.id)
            return ManagedSkillDTO(
                id: skill.id, name: skill.name, description: skill.description,
                sourceType: skill.sourceType, sourceRef: skill.sourceRef,
                centralPath: skill.centralPath, enabled: skill.enabled,
                status: skill.status, updateStatus: skill.updateStatus,
                targets: targets, tags: tags,
                createdAt: skill.createdAt, updatedAt: skill.updatedAt
            )
        }
    }

    /// Re-parse SKILL.md for all installed skills and update descriptions in DB
    func rescanDescriptions() {
        do {
            let skills = try database.getAllSkills()
            for skill in skills {
                let meta = SkillScanner.parseSkillMetadata(at: skill.centralPath)
                let newName = meta.name ?? skill.name
                let newDesc = meta.description ?? skill.description
                if newName != skill.name || newDesc != skill.description {
                    try? database.updateSkillDescription(id: skill.id, name: newName, description: newDesc)
                }
            }
        } catch {
            // Non-fatal: descriptions will show stale data
        }
    }

    // MARK: - Install

    func installFromLocal(path: String, name: String? = nil) throws -> ManagedSkillDTO {
        let source = URL(fileURLWithPath: path)
        let result = try installer.installFromLocal(source: source, name: name)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let skillId = UUID().uuidString

        let record = SkillRecord(
            id: skillId, name: result.name, description: result.description,
            sourceType: "local", sourceRef: path,
            sourceRefResolved: nil, sourceSubpath: nil, sourceBranch: nil,
            sourceRevision: nil, remoteRevision: nil,
            centralPath: result.centralPath.path,
            contentHash: result.contentHash,
            enabled: true, status: "ok", updateStatus: "unknown",
            lastCheckedAt: nil, lastCheckError: nil,
            createdAt: now, updatedAt: now
        )
        try database.insertSkill(record)
        return try makeDTO(skillId: skillId)
    }

    func installFromGit(url: String, branch: String? = nil, subpath: String? = nil, name: String? = nil, sourceType: String = "git") async throws -> ManagedSkillDTO {
        let key = "\(url)|\(branch ?? "")|\(subpath ?? "")"
        installLock.lock()
        guard installsInFlight.insert(key).inserted else {
            installLock.unlock()
            throw InstallerError.gitCloneFailed("Install already in progress for \(url)")
        }
        installLock.unlock()
        defer {
            installLock.lock()
            installsInFlight.remove(key)
            installLock.unlock()
        }

        let result = try await installer.installFromGit(url: url, branch: branch, subpath: subpath, name: name)
        let parsed = installer.parseGitSource(url)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let skillId = UUID().uuidString

        let record = SkillRecord(
            id: skillId, name: result.name, description: result.description,
            sourceType: sourceType, sourceRef: url,
            sourceRefResolved: parsed.cloneURL, sourceSubpath: parsed.subpath,
            sourceBranch: parsed.branch ?? branch, sourceRevision: nil,
            remoteRevision: nil, centralPath: result.centralPath.path,
            contentHash: result.contentHash,
            enabled: true, status: "ok", updateStatus: "unknown",
            lastCheckedAt: nil, lastCheckError: nil,
            createdAt: now, updatedAt: now
        )
        try database.insertSkill(record)
        return try makeDTO(skillId: skillId)
    }

    /// Install a skill from skills.sh marketplace.
    func installFromMarketplace(source: String, skillId: String? = nil, name: String? = nil) async throws -> ManagedSkillDTO {
        // source is GitHub shorthand (e.g., "vercel-labs/skills")
        // skillId is full path (e.g., "vercel-labs/skills/find-skills")
        // The skill lives at {repo}/skills/{skill-name}/ by convention
        var subpath: String?
        if let sid = skillId {
            let sourceParts = source.split(separator: "/")
            let idParts = sid.split(separator: "/")
            if idParts.count > sourceParts.count {
                let skillName = idParts[sourceParts.count...].joined(separator: "/")
                subpath = "skills/\(skillName)"
            }
        }
        return try await installFromGit(url: source, subpath: subpath, name: name, sourceType: "skillssh")
    }

    // MARK: - Uninstall

    func uninstallSkill(id: String) throws {
        guard let skill = try database.getSkill(id: id) else { return }

        // Remove all sync targets first (file system)
        let targets = try database.getTargets(forSkill: id)
        for target in targets {
            syncEngine.removeTarget(at: URL(fileURLWithPath: target.targetPath))
        }

        // Remove from central repo (file system)
        try installer.uninstall(centralPath: URL(fileURLWithPath: skill.centralPath))

        // Remove from database atomically (CASCADE handles targets + tags)
        try database.transaction {
            try database.deleteSkill(id: id)
        }
    }

    // MARK: - Sync to tools

    func syncToTool(skillId: String, toolKey: String) throws {
        guard let skill = try database.getSkill(id: skillId) else {
            throw SkillsManagerError.skillNotFound(skillId)
        }
        guard let adapter = try ToolAdapter.findAdapterIncludingDisabled(key: toolKey, db: database) else {
            throw SkillsManagerError.toolNotFound(toolKey)
        }

        let source = URL(fileURLWithPath: skill.centralPath)
        let skillName = URL(fileURLWithPath: skill.centralPath).lastPathComponent
        let target = adapter.skillsDir().appendingPathComponent(skillName)
        let mode = adapter.defaultSyncMode

        let actualMode = try syncEngine.sync(source: source, target: target, mode: mode)
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        let targetRecord = SkillTargetRecord(
            skillId: skillId, tool: toolKey,
            targetPath: target.path, mode: actualMode.rawValue,
            status: "ok", syncedAt: now, lastError: nil
        )
        try database.insertTarget(targetRecord)
    }

    func unsyncFromTool(skillId: String, toolKey: String) throws {
        let targets = try database.getTargets(forSkill: skillId)
        guard let target = targets.first(where: { $0.tool == toolKey }) else { return }

        syncEngine.removeTarget(at: URL(fileURLWithPath: target.targetPath))
        try database.deleteTarget(skillId: skillId, tool: toolKey)
    }

    func syncToAllTools(skillId: String) throws {
        let adapters = try ToolAdapter.allAdapters(db: database).filter { $0.isInstalled() }
        for adapter in adapters {
            try syncToTool(skillId: skillId, toolKey: adapter.key)
        }
    }

    // MARK: - Discovery

    func discoverSkills() throws -> [DiscoveredSkillRecord] {
        let managedSkills = try database.getAllSkills()
        let managedPaths = managedSkills.map(\.centralPath)

        // Also include all target paths as "managed"
        let allTargets = try database.getAllTargets()
        let targetPaths = allTargets.map(\.targetPath)

        let adapters = ToolAdapter.builtinAdapters().filter { $0.isInstalled() }
        let result = scanner.scanLocalSkills(managedPaths: managedPaths + targetPaths, adapters: adapters)

        // Build set of managed skill names (case-insensitive) for dedup
        let managedNames = Set(managedSkills.map { $0.name.lowercased() })

        // Check if discovered skills match already-imported ones by source_ref
        let sourceRefMap = Dictionary(managedSkills.compactMap { s in
            s.sourceRef.map { ($0, s.id) }
        }, uniquingKeysWith: { first, _ in first })

        var records = result.discovered
        for i in records.indices {
            if let skillId = sourceRefMap[records[i].foundPath] {
                records[i] = DiscoveredSkillRecord(
                    id: records[i].id, tool: records[i].tool,
                    foundPath: records[i].foundPath, nameGuess: records[i].nameGuess,
                    fingerprint: records[i].fingerprint, foundAt: records[i].foundAt,
                    importedSkillId: skillId
                )
            }
        }

        // Filter out already-imported and same-named skills (case-insensitive)
        records = records.filter { record in
            if record.importedSkillId != nil { return false }
            let name = (record.nameGuess ?? URL(fileURLWithPath: record.foundPath).lastPathComponent).lowercased()
            return !managedNames.contains(name)
        }

        // Store in database
        try database.clearDiscovered()
        for record in records {
            try database.insertDiscovered(record)
        }

        return records
    }

    func importDiscovered(discoveredId: String, name: String? = nil) throws -> ManagedSkillDTO {
        let all = try database.getAllDiscovered()
        guard let discovered = all.first(where: { $0.id == discoveredId }) else {
            throw SkillsManagerError.discoveredNotFound(discoveredId)
        }

        // Check if already imported
        if let existingId = discovered.importedSkillId,
           let existing = try? database.getSkill(id: existingId) {
            let targets = try database.getTargets(forSkill: existing.id)
            let tags = try database.getTags(forSkill: existing.id)
            return ManagedSkillDTO(
                id: existing.id, name: existing.name, description: existing.description,
                sourceType: existing.sourceType, sourceRef: existing.sourceRef,
                centralPath: existing.centralPath, enabled: existing.enabled,
                status: existing.status, updateStatus: existing.updateStatus,
                targets: targets, tags: tags,
                createdAt: existing.createdAt, updatedAt: existing.updatedAt
            )
        }

        return try installFromLocal(path: discovered.foundPath, name: name ?? discovered.nameGuess)
    }

    // MARK: - Tools status

    struct ToolStatus: Codable {
        let key: String
        let displayName: String
        let installed: Bool
        let enabled: Bool
        let isCustom: Bool
        let skillsDir: String
        let hasPathOverride: Bool
        let syncedSkillCount: Int
    }

    func getToolsStatus() throws -> [ToolStatus] {
        let allTargets = try database.getAllTargets()
        let disabledKeys = try ToolAdapter.loadDisabledTools(db: database)
        let pathOverrides = try ToolAdapter.loadCustomToolPaths(db: database)

        // Builtin adapters
        var results: [ToolStatus] = ToolAdapter.builtinAdapters().map { adapter in
            let count = allTargets.filter { $0.tool == adapter.key }.count
            let overridden = pathOverrides[adapter.key]
            let effectiveAdapter = overridden != nil
                ? ToolAdapter(key: adapter.key, displayName: adapter.displayName,
                             relativeSkillsDir: adapter.relativeSkillsDir, relativeDetectDir: adapter.relativeDetectDir,
                             additionalScanDirs: adapter.additionalScanDirs, overrideSkillsDir: overridden,
                             isCustom: false, recursiveScan: adapter.recursiveScan)
                : adapter
            return ToolStatus(
                key: adapter.key, displayName: adapter.displayName,
                installed: effectiveAdapter.isInstalled(), enabled: !disabledKeys.contains(adapter.key),
                isCustom: false, skillsDir: effectiveAdapter.skillsDir().path,
                hasPathOverride: overridden != nil,
                syncedSkillCount: count
            )
        }

        // Custom tools
        let customTools = (try? ToolAdapter.loadCustomTools(db: database)) ?? []
        for def in customTools {
            let count = allTargets.filter { $0.tool == def.key }.count
            results.append(ToolStatus(
                key: def.key, displayName: def.displayName,
                installed: true, enabled: !disabledKeys.contains(def.key),
                isCustom: true, skillsDir: def.skillsDir,
                hasPathOverride: false, syncedSkillCount: count
            ))
        }

        return results
    }

    // MARK: - Tool configuration

    func setToolEnabled(key: String, enabled: Bool) throws {
        var disabled = try ToolAdapter.loadDisabledTools(db: database)
        if enabled {
            disabled.remove(key)
        } else {
            disabled.insert(key)
        }
        try ToolAdapter.saveDisabledTools(disabled, db: database)
    }

    func setAllToolsEnabled(_ enabled: Bool) throws {
        if enabled {
            try ToolAdapter.saveDisabledTools([], db: database)
        } else {
            let allKeys = Set(ToolAdapter.builtinAdapters().map(\.key))
            try ToolAdapter.saveDisabledTools(allKeys, db: database)
        }
    }

    func setCustomToolPath(key: String, path: String) throws {
        var paths = try ToolAdapter.loadCustomToolPaths(db: database)
        paths[key] = path
        try ToolAdapter.saveCustomToolPaths(paths, db: database)
    }

    func resetCustomToolPath(key: String) throws {
        var paths = try ToolAdapter.loadCustomToolPaths(db: database)
        paths.removeValue(forKey: key)
        try ToolAdapter.saveCustomToolPaths(paths, db: database)
    }

    func addCustomTool(key: String, displayName: String, skillsDir: String) throws {
        // Validate no collision with builtins
        guard ToolAdapter.findAdapter(key: key) == nil else {
            throw SkillsManagerError.toolAlreadyExists(key)
        }
        var customs = try ToolAdapter.loadCustomTools(db: database)
        guard !customs.contains(where: { $0.key == key }) else {
            throw SkillsManagerError.toolAlreadyExists(key)
        }
        customs.append(ToolAdapter.CustomToolDef(
            key: key, displayName: displayName,
            skillsDir: skillsDir, projectRelativeSkillsDir: nil
        ))
        try ToolAdapter.saveCustomTools(customs, db: database)
    }

    func removeCustomTool(key: String) throws {
        var customs = try ToolAdapter.loadCustomTools(db: database)
        customs.removeAll { $0.key == key }
        try ToolAdapter.saveCustomTools(customs, db: database)
    }

    // MARK: - Marketplace

    func fetchMarketplace(type: LeaderboardType = .allTime) async throws -> [SkillsShSkill] {
        try await marketplace.fetchLeaderboard(type: type)
    }

    func searchMarketplace(query: String, limit: Int = 20) async throws -> [SkillsShSkill] {
        try await marketplace.searchSkills(query: query, limit: limit)
    }

    // MARK: - Tags

    func setSkillTags(id: String, tags: [String]) throws {
        guard try database.getSkill(id: id) != nil else {
            throw SkillsManagerError.skillNotFound(id)
        }
        try database.setTags(forSkill: id, tags: tags)
    }

    func getAllTags() throws -> [String] {
        try database.getAllTags()
    }

    func getSkillsByTag(tag: String) throws -> [ManagedSkillDTO] {
        let all = try listSkills()
        return all.filter { $0.tags.contains(tag) }
    }

    // MARK: - Skill document

    func getSkillDocument(id: String) throws -> String? {
        guard let skill = try database.getSkill(id: id) else { return nil }
        let dir = URL(fileURLWithPath: skill.centralPath)
        for name in ["SKILL.md", "skill.md"] {
            let file = dir.appendingPathComponent(name)
            if let content = try? String(contentsOf: file, encoding: .utf8) {
                return content
            }
        }
        return nil
    }

    // MARK: - Update checking

    private let checkTTL: TimeInterval = 3600 * 1000 // 60 min in ms

    /// Check a single skill for updates.
    func checkSkillUpdate(id: String, force: Bool = false) throws -> ManagedSkillDTO {
        guard let skill = try database.getSkill(id: id) else {
            throw SkillsManagerError.skillNotFound(id)
        }

        let now = Int64(Date().timeIntervalSince1970 * 1000)

        // Skip if checked recently (unless forced)
        if !force, let lastChecked = skill.lastCheckedAt,
           Double(now - lastChecked) < checkTTL {
            return try makeDTO(skillId: id)
        }

        switch skill.sourceType {
        case "git", "skillssh":
            let url = skill.sourceRefResolved ?? skill.sourceRef ?? ""
            guard !url.isEmpty else {
                try database.updateSkillCheckState(id: id, remoteRevision: nil, updateStatus: "error", lastCheckError: "No source URL")
                return try makeDTO(skillId: id)
            }
            do {
                let remoteRev = try installer.resolveRemoteRevision(url: url, branch: skill.sourceBranch)
                let status: String
                if let localRev = skill.sourceRevision, localRev == remoteRev {
                    status = "up_to_date"
                } else if skill.sourceRevision != nil {
                    status = "update_available"
                } else {
                    status = "unknown"
                }
                try database.updateSkillCheckState(id: id, remoteRevision: remoteRev, updateStatus: status, lastCheckError: nil)
            } catch {
                try database.updateSkillCheckState(id: id, remoteRevision: nil, updateStatus: "error", lastCheckError: error.localizedDescription)
            }

        case "local", "import":
            if let sourceRef = skill.sourceRef, FileManager.default.fileExists(atPath: sourceRef) {
                try database.updateSkillCheckState(id: id, remoteRevision: nil, updateStatus: "local_only", lastCheckError: nil)
            } else {
                try database.updateSkillCheckState(id: id, remoteRevision: nil, updateStatus: "source_missing", lastCheckError: nil)
            }

        default:
            try database.updateSkillCheckState(id: id, remoteRevision: nil, updateStatus: "unknown", lastCheckError: nil)
        }

        return try makeDTO(skillId: id)
    }

    /// Check all skills for updates.
    func checkAllUpdates(force: Bool = false) throws -> [ManagedSkillDTO] {
        let skills = try database.getAllSkills()
        var results: [ManagedSkillDTO] = []
        for skill in skills {
            let dto = try checkSkillUpdate(id: skill.id, force: force)
            results.append(dto)
        }
        return results
    }

    // MARK: - Update application

    struct UpdateResult: Codable {
        let skill: ManagedSkillDTO
        let contentChanged: Bool
    }

    /// Download and apply an update for a git-sourced skill.
    func updateSkill(id: String) throws -> UpdateResult {
        guard let skill = try database.getSkill(id: id) else {
            throw SkillsManagerError.skillNotFound(id)
        }
        guard skill.sourceType == "git" || skill.sourceType == "skillssh" else {
            throw SkillsManagerError.notUpdatable(id)
        }

        let url = skill.sourceRef ?? ""
        let centralPath = URL(fileURLWithPath: skill.centralPath)
        let oldHash = skill.contentHash

        // Set updating status
        try database.updateSkillCheckState(id: id, remoteRevision: skill.remoteRevision, updateStatus: "updating", lastCheckError: nil)

        do {
            let result = try installer.updateFromGit(
                url: url, branch: skill.sourceBranch, subpath: skill.sourceSubpath,
                currentCentralPath: centralPath
            )

            let contentChanged = result.contentHash != oldHash

            try database.transaction {
                try database.updateSkillAfterInstall(
                    id: id, name: result.name, description: result.description,
                    sourceRevision: skill.remoteRevision, remoteRevision: skill.remoteRevision,
                    contentHash: result.contentHash, updateStatus: "up_to_date"
                )
            }

            // Resync copy targets
            if contentChanged {
                try resyncCopyTargets(skillId: id, centralPath: centralPath)
            }

            let dto = try makeDTO(skillId: id)
            return UpdateResult(skill: dto, contentChanged: contentChanged)
        } catch {
            try database.updateSkillCheckState(id: id, remoteRevision: skill.remoteRevision, updateStatus: "error", lastCheckError: error.localizedDescription)
            throw error
        }
    }

    /// Batch update multiple skills.
    func batchUpdateSkills(ids: [String]) throws -> BatchUpdateResult {
        var refreshed = 0
        var unchanged = 0
        var failed: [String] = []

        for id in ids {
            do {
                guard let skill = try database.getSkill(id: id) else {
                    failed.append("Skill \(id) not found")
                    continue
                }
                if skill.sourceType == "git" || skill.sourceType == "skillssh" {
                    let result = try updateSkill(id: id)
                    if result.contentChanged { refreshed += 1 } else { unchanged += 1 }
                } else if skill.sourceType == "local" || skill.sourceType == "import" {
                    _ = try reimportLocalSkill(id: id)
                    refreshed += 1
                } else {
                    failed.append("Skill \(id) has unsupported source type: \(skill.sourceType)")
                }
            } catch {
                failed.append("Skill \(id): \(error.localizedDescription)")
            }
        }

        return BatchUpdateResult(refreshed: refreshed, unchanged: unchanged, failed: failed)
    }

    struct BatchUpdateResult: Codable {
        let refreshed: Int
        let unchanged: Int
        let failed: [String]
    }

    // MARK: - Reimport / Relink / Detach

    /// Re-import a local skill from its original source path.
    func reimportLocalSkill(id: String) throws -> ManagedSkillDTO {
        guard let skill = try database.getSkill(id: id) else {
            throw SkillsManagerError.skillNotFound(id)
        }
        guard skill.sourceType == "local" || skill.sourceType == "import" else {
            throw SkillsManagerError.notUpdatable(id)
        }
        guard let sourceRef = skill.sourceRef else {
            throw SkillsManagerError.sourceMissing(id)
        }

        try database.updateSkillCheckState(id: id, remoteRevision: nil, updateStatus: "updating", lastCheckError: nil)

        let result = try installer.reimportLocal(
            source: URL(fileURLWithPath: sourceRef),
            currentCentralPath: URL(fileURLWithPath: skill.centralPath)
        )

        try database.updateSkillAfterInstall(
            id: id, name: result.name, description: result.description,
            sourceRevision: nil, remoteRevision: nil,
            contentHash: result.contentHash, updateStatus: "local_only"
        )

        try resyncCopyTargets(skillId: id, centralPath: URL(fileURLWithPath: skill.centralPath))
        return try makeDTO(skillId: id)
    }

    /// Change the source path for a local skill and re-import.
    func relinkLocalSkillSource(id: String, newSourcePath: String) throws -> ManagedSkillDTO {
        guard let skill = try database.getSkill(id: id) else {
            throw SkillsManagerError.skillNotFound(id)
        }
        guard skill.sourceType == "local" || skill.sourceType == "import" else {
            throw SkillsManagerError.notUpdatable(id)
        }

        let source = URL(fileURLWithPath: newSourcePath)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw InstallerError.sourceNotFound(newSourcePath)
        }

        try database.updateSkillCheckState(id: id, remoteRevision: nil, updateStatus: "updating", lastCheckError: nil)

        let result = try installer.reimportLocal(
            source: source,
            currentCentralPath: URL(fileURLWithPath: skill.centralPath)
        )

        // Update source_ref to new path
        try database.updateSourceRef(id: id, sourceRef: newSourcePath)
        try database.updateSkillAfterInstall(
            id: id, name: result.name, description: result.description,
            sourceRevision: nil, remoteRevision: nil,
            contentHash: result.contentHash, updateStatus: "local_only"
        )

        try resyncCopyTargets(skillId: id, centralPath: URL(fileURLWithPath: skill.centralPath))
        return try makeDTO(skillId: id)
    }

    /// Detach source reference (forget original path, keep central copy).
    func detachLocalSkillSource(id: String) throws -> ManagedSkillDTO {
        guard let skill = try database.getSkill(id: id) else {
            throw SkillsManagerError.skillNotFound(id)
        }
        guard skill.sourceType == "local" || skill.sourceType == "import" else {
            throw SkillsManagerError.notUpdatable(id)
        }

        try database.updateSourceRef(id: id, sourceRef: nil)
        try database.updateSkillCheckState(id: id, remoteRevision: nil, updateStatus: "local_only", lastCheckError: nil)
        return try makeDTO(skillId: id)
    }

    // MARK: - Private: resync copy targets

    private func resyncCopyTargets(skillId: String, centralPath: URL) throws {
        let targets = try database.getTargets(forSkill: skillId)
        for target in targets where target.mode == "copy" {
            let targetURL = URL(fileURLWithPath: target.targetPath)
            _ = try syncEngine.sync(source: centralPath, target: targetURL, mode: .copy)
        }
    }

    // MARK: - Scenarios

    struct ScenarioDTO: Codable {
        let id: String
        let name: String
        let description: String?
        let icon: String?
        let sortOrder: Int32
        let skillCount: Int
        let isActive: Bool
        let createdAt: Int64
        let updatedAt: Int64
    }

    struct ScenarioDetailDTO: Codable {
        let scenario: ScenarioDTO
        let skills: [ManagedSkillDTO]
    }

    func listScenarios() throws -> [ScenarioDTO] {
        let scenarios = try database.getAllScenarios()
        let activeId = try database.getActiveScenarioId()
        return try scenarios.map { s in
            let count = try database.countSkillsForScenario(id: s.id)
            return ScenarioDTO(
                id: s.id, name: s.name, description: s.description,
                icon: s.icon, sortOrder: s.sortOrder, skillCount: count,
                isActive: s.id == activeId,
                createdAt: s.createdAt, updatedAt: s.updatedAt
            )
        }
    }

    func getActiveScenario() throws -> ScenarioDTO? {
        guard let activeId = try database.getActiveScenarioId(),
              let s = try database.getScenario(id: activeId) else { return nil }
        let count = try database.countSkillsForScenario(id: s.id)
        return ScenarioDTO(
            id: s.id, name: s.name, description: s.description,
            icon: s.icon, sortOrder: s.sortOrder, skillCount: count,
            isActive: true, createdAt: s.createdAt, updatedAt: s.updatedAt
        )
    }

    func getScenarioDetail(id: String) throws -> ScenarioDetailDTO {
        guard let s = try database.getScenario(id: id) else {
            throw SkillsManagerError.scenarioNotFound(id)
        }
        let activeId = try database.getActiveScenarioId()
        let count = try database.countSkillsForScenario(id: s.id)
        let dto = ScenarioDTO(
            id: s.id, name: s.name, description: s.description,
            icon: s.icon, sortOrder: s.sortOrder, skillCount: count,
            isActive: s.id == activeId,
            createdAt: s.createdAt, updatedAt: s.updatedAt
        )
        let skills = try database.getSkillsForScenario(id: id)
        let skillDTOs = try skills.map { skill in try makeDTO(skillId: skill.id) }
        return ScenarioDetailDTO(scenario: dto, skills: skillDTOs)
    }

    func createScenario(name: String, description: String? = nil, icon: String? = nil) throws -> ScenarioDTO {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let id = UUID().uuidString
        let scenarios = try database.getAllScenarios()
        let nextOrder = Int32((scenarios.map(\.sortOrder).max() ?? -1) + 1)

        let record = ScenarioRecord(
            id: id, name: name, description: description,
            icon: icon, sortOrder: nextOrder,
            createdAt: now, updatedAt: now
        )
        try database.insertScenario(record)

        // Unsync previous active scenario
        if let prevId = try database.getActiveScenarioId() {
            try unsyncScenarioSkills(scenarioId: prevId)
        }
        try database.setActiveScenario(id: id)

        return ScenarioDTO(
            id: id, name: name, description: description,
            icon: icon, sortOrder: nextOrder, skillCount: 0,
            isActive: true, createdAt: now, updatedAt: now
        )
    }

    func updateScenario(id: String, name: String, description: String? = nil, icon: String? = nil) throws {
        guard try database.getScenario(id: id) != nil else {
            throw SkillsManagerError.scenarioNotFound(id)
        }
        try database.updateScenario(id: id, name: name, description: description, icon: icon)
    }

    func deleteScenario(id: String) throws {
        let activeId = try database.getActiveScenarioId()
        let wasActive = (activeId == id)

        if wasActive {
            try unsyncScenarioSkills(scenarioId: id)
        }
        try database.deleteScenario(id: id)

        if wasActive {
            // Activate first remaining scenario
            let remaining = try database.getAllScenarios()
            if let first = remaining.first {
                try database.setActiveScenario(id: first.id)
                try syncScenarioSkills(scenarioId: first.id)
            } else {
                try database.setActiveScenario(id: nil)
            }
        }
    }

    func switchScenario(id: String) throws {
        guard try database.getScenario(id: id) != nil else {
            throw SkillsManagerError.scenarioNotFound(id)
        }

        // Unsync old scenario
        if let prevId = try database.getActiveScenarioId(), prevId != id {
            try unsyncScenarioSkills(scenarioId: prevId)
        }

        try database.setActiveScenario(id: id)
        try syncScenarioSkills(scenarioId: id)
    }

    func addSkillToScenario(scenarioId: String, skillId: String) throws {
        guard try database.getScenario(id: scenarioId) != nil else {
            throw SkillsManagerError.scenarioNotFound(scenarioId)
        }
        guard try database.getSkill(id: skillId) != nil else {
            throw SkillsManagerError.skillNotFound(skillId)
        }

        try database.addSkillToScenario(scenarioId: scenarioId, skillId: skillId)

        // Initialize tool toggles for all detected tools
        let adapters = try ToolAdapter.allAdapters(db: database)
        let installedKeys = adapters.filter { $0.isInstalled() }.map(\.key)
        try database.ensureScenarioSkillToolDefaults(scenarioId: scenarioId, skillId: skillId, tools: installedKeys)

        // Auto-sync if this is the active scenario
        let activeId = try database.getActiveScenarioId()
        if activeId == scenarioId {
            let enabledTools = try database.getEnabledToolsForScenarioSkill(scenarioId: scenarioId, skillId: skillId)
            for toolKey in enabledTools {
                try syncToTool(skillId: skillId, toolKey: toolKey)
            }
        }
    }

    func removeSkillFromScenario(scenarioId: String, skillId: String) throws {
        // Unsync if active
        let activeId = try database.getActiveScenarioId()
        if activeId == scenarioId {
            let enabledTools = try database.getEnabledToolsForScenarioSkill(scenarioId: scenarioId, skillId: skillId)
            for toolKey in enabledTools {
                try? unsyncFromTool(skillId: skillId, toolKey: toolKey)
            }
        }
        try database.removeSkillFromScenario(scenarioId: scenarioId, skillId: skillId)
    }

    func reorderScenarios(ids: [String]) throws {
        try database.reorderScenarios(ids: ids)
    }

    func reorderScenarioSkills(scenarioId: String, skillIds: [String]) throws {
        try database.reorderScenarioSkills(scenarioId: scenarioId, skillIds: skillIds)
    }

    // MARK: Scenario helpers

    private func syncScenarioSkills(scenarioId: String) throws {
        let skillIds = try database.getSkillIdsForScenario(id: scenarioId)
        for skillId in skillIds {
            let enabledTools = try database.getEnabledToolsForScenarioSkill(scenarioId: scenarioId, skillId: skillId)
            // If no tool toggles set, sync to all installed tools
            let toolKeys: [String]
            if enabledTools.isEmpty {
                let adapters = try ToolAdapter.allAdapters(db: database)
                toolKeys = adapters.filter { $0.isInstalled() }.map(\.key)
            } else {
                toolKeys = enabledTools
            }
            for toolKey in toolKeys {
                try? syncToTool(skillId: skillId, toolKey: toolKey)
            }
        }
    }

    private func unsyncScenarioSkills(scenarioId: String) throws {
        let skillIds = try database.getSkillIdsForScenario(id: scenarioId)
        for skillId in skillIds {
            let targets = try database.getTargets(forSkill: skillId)
            for target in targets {
                try? unsyncFromTool(skillId: skillId, toolKey: target.tool)
            }
        }
    }

    // MARK: - Marketplace Repos

    struct RepoSkillInfo: Codable {
        let name: String
        let description: String
        let path: String
        let repoUrl: String
    }

    func getMarketplaceRepos() throws -> [[String: Any]] {
        guard let json = try database.getSetting("marketplace_repos"),
              let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr
    }

    func addMarketplaceRepo(url: String, name: String?) throws -> [String: Any] {
        var repos = try getMarketplaceRepos()
        // Prevent duplicates
        if repos.contains(where: { ($0["url"] as? String) == url }) {
            return repos.first(where: { ($0["url"] as? String) == url })!
        }
        let repoName = name ?? url.split(separator: "/").suffix(2).joined(separator: "/")
            .replacingOccurrences(of: ".git", with: "")
        let entry: [String: Any] = [
            "url": url,
            "name": repoName,
            "addedAt": ISO8601DateFormatter().string(from: Date())
        ]
        repos.append(entry)
        let data = try JSONSerialization.data(withJSONObject: repos)
        try database.setSetting("marketplace_repos", value: String(data: data, encoding: .utf8))
        return entry
    }

    func removeMarketplaceRepo(url: String) throws {
        var repos = try getMarketplaceRepos()
        repos.removeAll(where: { ($0["url"] as? String) == url })
        let data = try JSONSerialization.data(withJSONObject: repos)
        try database.setSetting("marketplace_repos", value: String(data: data, encoding: .utf8))
    }

    func scanMarketplaceRepo(url: String) async throws -> [RepoSkillInfo] {
        // Check cache first
        let cacheKey = "marketplace_repo_cache_\(url.hashValue)"
        if let cached = try? database.getSetting(cacheKey),
           let cacheData = cached.data(using: .utf8),
           let cacheObj = try? JSONSerialization.jsonObject(with: cacheData) as? [String: Any],
           let ts = cacheObj["ts"] as? Double,
           Date().timeIntervalSince1970 - ts < 300,
           let skillsData = try? JSONSerialization.data(withJSONObject: cacheObj["skills"] ?? []),
           let skills = try? JSONDecoder().decode([RepoSkillInfo].self, from: skillsData) {
            return skills
        }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("clawd-repo-scan-\(UUID().uuidString)")

        defer { try? fm.removeItem(at: tempDir) }

        // Shallow clone with timeout — inherit user environment for SSH auth
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["clone", "--depth", "1", "--single-branch", url, tempDir.path]
        process.environment = ProcessInfo.processInfo.environment
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe

        try process.run()

        // Timeout after 30 seconds
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        if process.isRunning {
            process.terminate()
            throw SkillsManagerError.sourceMissing("Git clone timed out for: \(url)")
        }
        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw SkillsManagerError.sourceMissing("Git clone failed for \(url): \(errMsg)")
        }

        // Scan root and one level of child directories for SKILL.md
        var results: [RepoSkillInfo] = []
        let skillFileNames = ["SKILL.md", "skill.md"]

        // Check root
        for name in skillFileNames {
            let rootSkill = tempDir.appendingPathComponent(name)
            if fm.fileExists(atPath: rootSkill.path) {
                let description = parseSkillDescription(at: rootSkill)
                let repoName = URL(string: url)?.deletingPathExtension().lastPathComponent ?? "skill"
                results.append(RepoSkillInfo(name: repoName, description: description, path: ".", repoUrl: url))
                break
            }
        }

        // Check one level deep child directories
        if let children = try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let childName = child.lastPathComponent
                if childName.hasPrefix(".") { continue }
                for name in skillFileNames {
                    let skillFile = child.appendingPathComponent(name)
                    if fm.fileExists(atPath: skillFile.path) {
                        let description = parseSkillDescription(at: skillFile)
                        results.append(RepoSkillInfo(name: childName, description: description, path: childName, repoUrl: url))
                        break
                    }
                }
            }
        }

        // Cache results
        let encoded = try JSONEncoder().encode(results)
        let cacheObj: [String: Any] = [
            "ts": Date().timeIntervalSince1970,
            "skills": (try? JSONSerialization.jsonObject(with: encoded)) ?? []
        ]
        let cacheData = try JSONSerialization.data(withJSONObject: cacheObj)
        try? database.setSetting(cacheKey, value: String(data: cacheData, encoding: .utf8))

        return results
    }

    // MARK: - Private helpers

    private func parseSkillDescription(at fileURL: URL) -> String {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return "" }
        let lines = content.components(separatedBy: .newlines)
        // Look for description in frontmatter or first non-heading non-empty lines
        var description = ""
        var inFrontmatter = false
        for (i, line) in lines.enumerated() {
            if i == 0 && line.trimmingCharacters(in: .whitespaces) == "---" { inFrontmatter = true; continue }
            if inFrontmatter {
                if line.trimmingCharacters(in: .whitespaces) == "---" { inFrontmatter = false; continue }
                if line.lowercased().hasPrefix("description:") {
                    description = line.replacingOccurrences(of: "description:", with: "", options: .caseInsensitive)
                        .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    break
                }
                continue
            }
            if line.hasPrefix("#") || line.isEmpty { continue }
            description = line.trimmingCharacters(in: .whitespaces)
            break
        }
        if description.count > 200 { description = String(description.prefix(200)) + "..." }
        return description
    }

    private func makeDTO(skillId: String) throws -> ManagedSkillDTO {
        guard let skill = try database.getSkill(id: skillId) else {
            throw SkillsManagerError.skillNotFound(skillId)
        }
        let targets = try database.getTargets(forSkill: skillId)
        let tags = try database.getTags(forSkill: skillId)
        return ManagedSkillDTO(
            id: skill.id, name: skill.name, description: skill.description,
            sourceType: skill.sourceType, sourceRef: skill.sourceRef,
            centralPath: skill.centralPath, enabled: skill.enabled,
            status: skill.status, updateStatus: skill.updateStatus,
            targets: targets, tags: tags,
            createdAt: skill.createdAt, updatedAt: skill.updatedAt
        )
    }
}

// MARK: - Errors

enum SkillsManagerError: LocalizedError {
    case skillNotFound(String)
    case toolNotFound(String)
    case discoveredNotFound(String)
    case notUpdatable(String)
    case sourceMissing(String)
    case toolAlreadyExists(String)
    case scenarioNotFound(String)

    var errorDescription: String? {
        switch self {
        case .skillNotFound(let id): return "Skill not found: \(id)"
        case .toolNotFound(let key): return "Tool not found: \(key)"
        case .discoveredNotFound(let id): return "Discovered skill not found: \(id)"
        case .notUpdatable(let id): return "Skill \(id) is not updatable (not git/local source)"
        case .sourceMissing(let id): return "Source path missing for skill: \(id)"
        case .toolAlreadyExists(let key): return "Tool already exists: \(key)"
        case .scenarioNotFound(let id): return "Scenario not found: \(id)"
        }
    }
}
