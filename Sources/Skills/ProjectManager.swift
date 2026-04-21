import Foundation

// MARK: - DTOs

struct ProjectDTO: Codable {
    let id: String
    let name: String
    let path: String
    let workspaceType: String
    let linkedAgentKey: String?
    let linkedAgentName: String?
    let supportsSkillToggle: Bool
    let skillCount: Int
    let syncHealth: SyncHealth
    let sortOrder: Int32
    let createdAt: Int64
    let updatedAt: Int64
}

struct SyncHealth: Codable {
    let inSync: Int
    let projectNewer: Int
    let centerNewer: Int
    let diverged: Int
    let projectOnly: Int
}

struct ProjectSkillDTO: Codable {
    let name: String
    let relativePath: String
    let path: String
    let agent: String
    let agentDisplayName: String
    let enabled: Bool
    let tags: [String]
    let inCenter: Bool
    let syncStatus: String  // in_sync | project_only | project_newer | center_newer | diverged
    let centerSkillId: String?
}

struct ProjectAgentTarget: Codable {
    let key: String
    let displayName: String
    let skillCount: Int
    let enabledCount: Int
}

// MARK: - Agent definitions

struct ProjectAgentDef {
    let key: String
    let displayName: String
    let skillsDirName: String      // under .claude/skills/
    let detectDirName: String?     // detect presence by this dir under .claude/
}

private let knownProjectAgents: [ProjectAgentDef] = [
    ProjectAgentDef(key: "claude_code", displayName: "Claude Code",
                    skillsDirName: ".", detectDirName: nil),
    ProjectAgentDef(key: "cursor", displayName: "Cursor",
                    skillsDirName: "cursor", detectDirName: "cursor"),
    ProjectAgentDef(key: "github_copilot", displayName: "GitHub Copilot",
                    skillsDirName: "github-copilot", detectDirName: "github-copilot"),
    ProjectAgentDef(key: "windsurf", displayName: "Windsurf",
                    skillsDirName: "windsurf", detectDirName: "windsurf"),
    ProjectAgentDef(key: "codex", displayName: "Codex",
                    skillsDirName: "codex", detectDirName: "codex"),
]

// MARK: - ProjectManager

final class ProjectManager {
    private let db: SkillDatabase
    private let fm = FileManager.default

    init(db: SkillDatabase) {
        self.db = db
    }

    // MARK: - Project CRUD

    func listProjects() throws -> [ProjectDTO] {
        let records = try db.getAllProjects()
        return records.map { makeDTO($0) }
    }

    func getProject(id: String) throws -> ProjectDTO {
        guard let rec = try db.getProject(id: id) else {
            throw ProjectError.notFound
        }
        return makeDTO(rec)
    }

    func addProject(path: String) throws -> ProjectDTO {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
        let absPath = url.path

        guard fm.fileExists(atPath: absPath) else {
            throw ProjectError.pathNotFound(absPath)
        }

        if let _ = try db.getProjectByPath(absPath) {
            throw ProjectError.alreadyExists(absPath)
        }

        // Create .claude/skills/ structure if needed
        let claudeDir = url.appendingPathComponent(".claude")
        let skillsDir = claudeDir.appendingPathComponent("skills")
        let disabledDir = claudeDir.appendingPathComponent("skills-disabled")
        try fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: disabledDir, withIntermediateDirectories: true)

        let name = url.lastPathComponent
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let count = try db.getProjectCount()

        let record = ProjectRecord(
            id: UUID().uuidString.lowercased(),
            name: name, path: absPath, workspaceType: "project",
            linkedAgentKey: nil, linkedAgentName: nil, disabledPath: nil,
            sortOrder: Int32(count), createdAt: now, updatedAt: now
        )
        try db.insertProject(record)
        return makeDTO(record)
    }

    func removeProject(id: String) throws {
        guard let _ = try db.getProject(id: id) else {
            throw ProjectError.notFound
        }
        try db.deleteProject(id: id)
    }

    func reorderProjects(ids: [String]) throws {
        try db.reorderProjects(ids: ids)
    }

    // MARK: - Scan for projects

    func scanProjects(root: String, maxDepth: Int = 4) throws -> [String] {
        let rootURL = URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
            .standardizedFileURL
        var found: [String] = []
        scanRecursive(dir: rootURL, depth: 0, maxDepth: maxDepth, results: &found)
        return found
    }

    private func scanRecursive(dir: URL, depth: Int, maxDepth: Int, results: inout [String]) {
        guard depth < maxDepth else { return }
        let claudeSkills = dir.appendingPathComponent(".claude/skills")
        if fm.fileExists(atPath: claudeSkills.path) {
            results.append(dir.path)
            return
        }
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles]) else { return }
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            scanRecursive(dir: entry, depth: depth + 1, maxDepth: maxDepth, results: &results)
        }
    }

    // MARK: - Agent targets

    func getAgentTargets(projectId: String) throws -> [ProjectAgentTarget] {
        guard let rec = try db.getProject(id: projectId) else {
            throw ProjectError.notFound
        }

        if rec.workspaceType == "linked" {
            return []
        }

        let claudeSkills = URL(fileURLWithPath: rec.path).appendingPathComponent(".claude/skills")
        let claudeDisabled = URL(fileURLWithPath: rec.path).appendingPathComponent(".claude/skills-disabled")
        var targets: [ProjectAgentTarget] = []

        for agent in knownProjectAgents {
            let skillsDir: URL
            let disabledDir: URL
            if agent.key == "claude_code" {
                skillsDir = claudeSkills
                disabledDir = claudeDisabled
            } else {
                skillsDir = claudeSkills.appendingPathComponent(agent.skillsDirName)
                disabledDir = claudeDisabled.appendingPathComponent(agent.skillsDirName)
            }

            let enabledSkills = listSkillsInDir(skillsDir)
            let disabledSkills = listSkillsInDir(disabledDir)
            let total = enabledSkills.count + disabledSkills.count
            if total > 0 || agent.key == "claude_code" {
                targets.append(ProjectAgentTarget(
                    key: agent.key, displayName: agent.displayName,
                    skillCount: total, enabledCount: enabledSkills.count
                ))
            }
        }
        return targets
    }

    // MARK: - Project skills

    func getProjectSkills(projectId: String, agent: String? = nil) throws -> [ProjectSkillDTO] {
        guard let rec = try db.getProject(id: projectId) else {
            throw ProjectError.notFound
        }

        let allCentralSkills = try db.getAllSkills()
        var results: [ProjectSkillDTO] = []

        let agentsToScan: [String]
        if let specificAgent = agent {
            agentsToScan = [specificAgent]
        } else {
            let targets = try getAgentTargets(projectId: projectId)
            agentsToScan = targets.map { $0.key }
        }

        for agentKey in agentsToScan {
            let agentName = knownProjectAgents.first { $0.key == agentKey }?.displayName
                ?? agentKey
            let (enabledDir, disabledDir) = skillDirsForAgent(project: rec, agentKey: agentKey)

            // Enabled skills
            for entry in listSkillsInDir(enabledDir) {
                let relativePath = agentKey == "claude_code" ? entry : "\(agentKey)/\(entry)"
                let fullPath = enabledDir.appendingPathComponent(entry).path
                let (syncStatus, centerId) = computeSyncStatus(
                    skillPath: fullPath, centralSkills: allCentralSkills, skillName: entry)
                let tags = centerId.flatMap { try? db.getTags(forSkill: $0) } ?? []
                results.append(ProjectSkillDTO(
                    name: entry, relativePath: relativePath, path: fullPath,
                    agent: agentKey, agentDisplayName: agentName,
                    enabled: true, tags: tags, inCenter: centerId != nil,
                    syncStatus: syncStatus, centerSkillId: centerId
                ))
            }

            // Disabled skills
            for entry in listSkillsInDir(disabledDir) {
                let relativePath = agentKey == "claude_code" ? entry : "\(agentKey)/\(entry)"
                let fullPath = disabledDir.appendingPathComponent(entry).path
                let (syncStatus, centerId) = computeSyncStatus(
                    skillPath: fullPath, centralSkills: allCentralSkills, skillName: entry)
                let tags = centerId.flatMap { try? db.getTags(forSkill: $0) } ?? []
                results.append(ProjectSkillDTO(
                    name: entry, relativePath: relativePath, path: fullPath,
                    agent: agentKey, agentDisplayName: agentName,
                    enabled: false, tags: tags, inCenter: centerId != nil,
                    syncStatus: syncStatus, centerSkillId: centerId
                ))
            }
        }

        return results.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    // MARK: - Toggle skill (enable/disable)

    func toggleProjectSkill(projectId: String, skillPath: String, agent: String, enabled: Bool) throws {
        guard let rec = try db.getProject(id: projectId) else {
            throw ProjectError.notFound
        }
        guard rec.workspaceType == "project" else {
            throw ProjectError.toggleNotSupported
        }

        let (enabledDir, disabledDir) = skillDirsForAgent(project: rec, agentKey: agent)
        let skillName = URL(fileURLWithPath: skillPath).lastPathComponent

        let sourceDir = enabled ? disabledDir : enabledDir
        let targetDir = enabled ? enabledDir : disabledDir
        let sourcePath = sourceDir.appendingPathComponent(skillName)
        let targetPath = targetDir.appendingPathComponent(skillName)

        guard fm.fileExists(atPath: sourcePath.path) else {
            throw ProjectError.skillNotFound(skillName)
        }

        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

        // Remove any existing symlink duplicate at target
        if fm.fileExists(atPath: targetPath.path) {
            try fm.removeItem(at: targetPath)
        }

        try fm.moveItem(at: sourcePath, to: targetPath)
    }

    // MARK: - Delete project skill

    func deleteProjectSkill(projectId: String, skillPath: String, agent: String) throws {
        guard let _ = try db.getProject(id: projectId) else {
            throw ProjectError.notFound
        }

        let url = URL(fileURLWithPath: skillPath)
        guard fm.fileExists(atPath: url.path) else {
            throw ProjectError.skillNotFound(url.lastPathComponent)
        }
        try fm.removeItem(at: url)
    }

    // MARK: - Import project skill to center

    func importProjectSkillToCenter(projectId: String, skillPath: String, agent: String) throws -> String {
        guard let _ = try db.getProject(id: projectId) else {
            throw ProjectError.notFound
        }

        let sourceURL = URL(fileURLWithPath: skillPath)
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw ProjectError.skillNotFound(sourceURL.lastPathComponent)
        }

        let skillName = sourceURL.lastPathComponent
        let centralBase = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".clawd/skills")
        let centralDest = centralBase.appendingPathComponent(skillName)

        // If already in center with same name, generate unique name
        var finalDest = centralDest
        var counter = 1
        while fm.fileExists(atPath: finalDest.path) {
            finalDest = centralBase.appendingPathComponent("\(skillName)-\(counter)")
            counter += 1
        }

        try fm.createDirectory(at: centralBase, withIntermediateDirectories: true)
        try copyDirectory(from: sourceURL, to: finalDest)

        let hash = computeContentHash(at: finalDest)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let id = UUID().uuidString.lowercased()

        let record = SkillRecord(
            id: id, name: finalDest.lastPathComponent, description: nil,
            sourceType: "local", sourceRef: skillPath, sourceRefResolved: nil,
            sourceSubpath: nil, sourceBranch: nil, sourceRevision: nil,
            remoteRevision: nil, centralPath: finalDest.path, contentHash: hash,
            enabled: true, status: "ok", updateStatus: "unknown",
            lastCheckedAt: nil, lastCheckError: nil, createdAt: now, updatedAt: now
        )
        try db.insertSkill(record)
        return id
    }

    // MARK: - Export center skill to project

    func exportSkillToProject(skillId: String, projectId: String, agents: [String]?) throws {
        guard let rec = try db.getProject(id: projectId) else {
            throw ProjectError.notFound
        }
        guard let skill = try db.getSkill(id: skillId) else {
            throw ProjectError.skillNotFound(skillId)
        }

        let centralURL = URL(fileURLWithPath: skill.centralPath)
        let skillName = centralURL.lastPathComponent

        let targetAgents: [String]
        if let specified = agents, !specified.isEmpty {
            targetAgents = specified
        } else {
            targetAgents = ["claude_code"]
        }

        for agentKey in targetAgents {
            let (enabledDir, _) = skillDirsForAgent(project: rec, agentKey: agentKey)
            let targetPath = enabledDir.appendingPathComponent(skillName)
            try fm.createDirectory(at: enabledDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: targetPath.path) {
                try fm.removeItem(at: targetPath)
            }
            try copyDirectory(from: centralURL, to: targetPath)
        }
    }

    // MARK: - Sync: update project skill from center

    func updateProjectSkillFromCenter(projectId: String, skillPath: String, centerSkillId: String) throws {
        guard let _ = try db.getProject(id: projectId) else {
            throw ProjectError.notFound
        }
        guard let skill = try db.getSkill(id: centerSkillId) else {
            throw ProjectError.skillNotFound(centerSkillId)
        }

        let centralURL = URL(fileURLWithPath: skill.centralPath)
        let targetURL = URL(fileURLWithPath: skillPath)

        guard fm.fileExists(atPath: centralURL.path) else {
            throw ProjectError.centerSkillMissing(centerSkillId)
        }

        if fm.fileExists(atPath: targetURL.path) {
            try fm.removeItem(at: targetURL)
        }
        try copyDirectory(from: centralURL, to: targetURL)
    }

    // MARK: - Sync: update center skill from project

    func updateCenterSkillFromProject(projectId: String, skillPath: String, centerSkillId: String) throws {
        guard let _ = try db.getProject(id: projectId) else {
            throw ProjectError.notFound
        }
        guard let skill = try db.getSkill(id: centerSkillId) else {
            throw ProjectError.skillNotFound(centerSkillId)
        }

        let sourceURL = URL(fileURLWithPath: skillPath)
        let centralURL = URL(fileURLWithPath: skill.centralPath)

        guard fm.fileExists(atPath: sourceURL.path) else {
            throw ProjectError.skillNotFound(skillPath)
        }

        if fm.fileExists(atPath: centralURL.path) {
            try fm.removeItem(at: centralURL)
        }
        try copyDirectory(from: sourceURL, to: centralURL)

        let hash = computeContentHash(at: centralURL)
        try db.updateSkillContentHash(id: centerSkillId, contentHash: hash)
    }

    // MARK: - Read skill document

    func getProjectSkillDocument(projectId: String, skillPath: String) throws -> String? {
        guard let _ = try db.getProject(id: projectId) else {
            throw ProjectError.notFound
        }

        let dir = URL(fileURLWithPath: skillPath)
        let candidates = ["SKILL.md", "CLAUDE.md", "README.md"]
        for name in candidates {
            let file = dir.appendingPathComponent(name)
            if let content = try? String(contentsOf: file, encoding: .utf8) {
                return content
            }
        }

        // If skillPath is itself a file
        if !dir.hasDirectoryPath, fm.fileExists(atPath: dir.path) {
            return try? String(contentsOf: dir, encoding: .utf8)
        }

        return nil
    }

    // MARK: - Diff between project and center skill

    func diffProjectSkill(projectId: String, skillPath: String, centerSkillId: String) throws -> DiffResult {
        guard let _ = try db.getProject(id: projectId) else {
            throw ProjectError.notFound
        }
        guard let skill = try db.getSkill(id: centerSkillId) else {
            throw ProjectError.skillNotFound(centerSkillId)
        }

        let projectURL = URL(fileURLWithPath: skillPath)
        let centerURL = URL(fileURLWithPath: skill.centralPath)

        let projectFiles = collectFiles(at: projectURL)
        let centerFiles = collectFiles(at: centerURL)

        let allNames = Set(projectFiles.keys).union(centerFiles.keys)
        var diffs: [FileDiff] = []

        for name in allNames.sorted() {
            let pContent = projectFiles[name]
            let cContent = centerFiles[name]

            if pContent == cContent { continue }

            diffs.append(FileDiff(
                fileName: name,
                projectContent: pContent,
                centerContent: cContent,
                status: pContent == nil ? "center_only" :
                        cContent == nil ? "project_only" : "modified"
            ))
        }

        return DiffResult(
            skillName: projectURL.lastPathComponent,
            centerSkillId: centerSkillId,
            files: diffs
        )
    }

    // MARK: - Helpers

    private func makeDTO(_ rec: ProjectRecord) -> ProjectDTO {
        let skills = (try? getProjectSkills(projectId: rec.id)) ?? []
        let health = computeSyncHealth(skills: skills)
        return ProjectDTO(
            id: rec.id, name: rec.name, path: rec.path,
            workspaceType: rec.workspaceType,
            linkedAgentKey: rec.linkedAgentKey,
            linkedAgentName: rec.linkedAgentName,
            supportsSkillToggle: true,
            skillCount: skills.count, syncHealth: health,
            sortOrder: rec.sortOrder,
            createdAt: rec.createdAt, updatedAt: rec.updatedAt
        )
    }

    private func computeSyncHealth(skills: [ProjectSkillDTO]) -> SyncHealth {
        var inSync = 0, projectNewer = 0, centerNewer = 0, diverged = 0, projectOnly = 0
        for s in skills {
            switch s.syncStatus {
            case "in_sync": inSync += 1
            case "project_newer": projectNewer += 1
            case "center_newer": centerNewer += 1
            case "diverged": diverged += 1
            case "project_only": projectOnly += 1
            default: break
            }
        }
        return SyncHealth(inSync: inSync, projectNewer: projectNewer,
                          centerNewer: centerNewer, diverged: diverged, projectOnly: projectOnly)
    }

    private func skillDirsForAgent(project: ProjectRecord, agentKey: String) -> (enabled: URL, disabled: URL) {
        let base = URL(fileURLWithPath: project.path)
        let enabledBase = base.appendingPathComponent(".claude/skills")
        let disabledBase = base.appendingPathComponent(".claude/skills-disabled")

        if agentKey == "claude_code" {
            return (enabledBase, disabledBase)
        }
        let agentDir = knownProjectAgents.first { $0.key == agentKey }?.skillsDirName ?? agentKey
        return (enabledBase.appendingPathComponent(agentDir),
                disabledBase.appendingPathComponent(agentDir))
    }

    private func listSkillsInDir(_ dir: URL) -> [String] {
        guard let entries = try? fm.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }

        return entries.compactMap { url -> String? in
            // Skip known non-skill agent subdirs at top level
            let name = url.lastPathComponent
            if knownProjectAgents.contains(where: { $0.skillsDirName == name && $0.key != "claude_code" }) {
                return nil
            }
            // Skill is either a .md file or a directory
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir || name.hasSuffix(".md") {
                return name
            }
            return nil
        }.sorted()
    }

    private func computeSyncStatus(skillPath: String, centralSkills: [SkillRecord], skillName: String) -> (String, String?) {
        // Try to find matching central skill by name
        let match = centralSkills.first { URL(fileURLWithPath: $0.centralPath).lastPathComponent == skillName }

        guard let match = match else {
            return ("project_only", nil)
        }

        let projectHash = computeContentHash(at: URL(fileURLWithPath: skillPath))
        if projectHash == match.contentHash && projectHash != nil {
            return ("in_sync", match.id)
        }

        // Compare modification times
        let projectMod = modTime(skillPath)
        let centerMod = modTime(match.centralPath)

        if let pm = projectMod, let cm = centerMod {
            let threshold: TimeInterval = 2.0
            if pm > cm + threshold {
                return ("project_newer", match.id)
            } else if cm > pm + threshold {
                return ("center_newer", match.id)
            }
        }

        return ("diverged", match.id)
    }

    private func modTime(_ path: String) -> TimeInterval? {
        (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970
    }

    private func computeContentHash(at url: URL) -> String? {
        // Simple hash: concatenate all file contents and hash
        let files = collectFiles(at: url)
        guard !files.isEmpty else { return nil }

        var combined = ""
        for key in files.keys.sorted() {
            combined += key + ":" + (files[key] ?? "") + "\n"
        }

        // Simple djb2 hash
        var hash: UInt64 = 5381
        for char in combined.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(char)
        }
        return String(hash, radix: 16)
    }

    private func collectFiles(at url: URL) -> [String: String] {
        var result: [String: String] = [:]
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

        if !isDir {
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                result[url.lastPathComponent] = content
            }
            return result
        }

        let resolvedBase = url.standardizedFileURL.path + "/"
        guard let enumerator = fm.enumerator(at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return result }

        while let fileURL = enumerator.nextObject() as? URL {
            let isFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isFile else { continue }
            let filePath = fileURL.standardizedFileURL.path
            let relativePath = filePath.hasPrefix(resolvedBase)
                ? String(filePath.dropFirst(resolvedBase.count))
                : fileURL.lastPathComponent
            if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                result[relativePath] = content
            }
        }
        return result
    }

    private func copyDirectory(from: URL, to: URL) throws {
        let isDir = (try? from.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDir {
            try fm.copyItem(at: from, to: to)
        } else {
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: from, to: to)
        }
    }
}

// MARK: - Diff types

struct FileDiff: Codable {
    let fileName: String
    let projectContent: String?
    let centerContent: String?
    let status: String  // modified | project_only | center_only
}

struct DiffResult: Codable {
    let skillName: String
    let centerSkillId: String
    let files: [FileDiff]
}

// MARK: - Errors

enum ProjectError: LocalizedError {
    case notFound
    case pathNotFound(String)
    case alreadyExists(String)
    case skillNotFound(String)
    case centerSkillMissing(String)
    case toggleNotSupported

    var errorDescription: String? {
        switch self {
        case .notFound: return "Project not found"
        case .pathNotFound(let p): return "Path not found: \(p)"
        case .alreadyExists(let p): return "Project already exists: \(p)"
        case .skillNotFound(let s): return "Skill not found: \(s)"
        case .centerSkillMissing(let s): return "Center skill missing: \(s)"
        case .toggleNotSupported: return "Toggle not supported for this workspace type"
        }
    }
}
