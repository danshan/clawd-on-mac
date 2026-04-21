import Foundation

/// Git-based backup for the central skills directory (~/.clawd/skills/).
/// All operations shell out to the native `git` CLI.
final class GitBackup {

    struct Status: Codable {
        let isRepo: Bool
        let remoteURL: String?
        let branch: String?
        let hasChanges: Bool
        let ahead: Int
        let behind: Int
        let lastCommit: String?
        let lastCommitTime: String?
        let currentSnapshotTag: String?
    }

    struct Version: Codable {
        let tag: String
        let commit: String
        let message: String
        let committedAt: String
    }

    enum BackupError: LocalizedError {
        case notARepo
        case gitFailed(String)
        case nothingToCommit
        case noRemote
        case tagNotFound(String)

        var errorDescription: String? {
            switch self {
            case .notARepo: return "Skills directory is not a git repository. Run init first."
            case .gitFailed(let msg): return "Git operation failed: \(msg)"
            case .nothingToCommit: return "No changes to commit"
            case .noRemote: return "No remote configured. Set a remote URL first."
            case .tagNotFound(let tag): return "Snapshot tag not found: \(tag)"
            }
        }
    }

    private let skillsDir: URL

    init(skillsDir: URL) {
        self.skillsDir = skillsDir
    }

    // MARK: - Status

    func getStatus() -> Status {
        let isRepo = FileManager.default.fileExists(atPath: skillsDir.appendingPathComponent(".git").path)
        guard isRepo else {
            return Status(isRepo: false, remoteURL: nil, branch: nil, hasChanges: false,
                          ahead: 0, behind: 0, lastCommit: nil, lastCommitTime: nil,
                          currentSnapshotTag: nil)
        }

        let remote = try? git("config", "--get", "remote.origin.url")
        let branch = try? git("rev-parse", "--abbrev-ref", "HEAD")
        let hasChanges = (try? git("status", "--porcelain")).map { !$0.isEmpty } ?? false
        let (ahead, behind) = getAheadBehind()
        let lastCommit = try? git("log", "-1", "--format=%s")
        let lastCommitTime = try? git("log", "-1", "--format=%aI")
        let snapshotTag = try? git("tag", "--points-at", "HEAD", "--list", "sm-v-*")

        return Status(
            isRepo: true,
            remoteURL: remote?.trimmingCharacters(in: .whitespacesAndNewlines),
            branch: branch?.trimmingCharacters(in: .whitespacesAndNewlines),
            hasChanges: hasChanges,
            ahead: ahead, behind: behind,
            lastCommit: lastCommit?.trimmingCharacters(in: .whitespacesAndNewlines),
            lastCommitTime: lastCommitTime?.trimmingCharacters(in: .whitespacesAndNewlines),
            currentSnapshotTag: snapshotTag?.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first
        )
    }

    // MARK: - Init

    func initRepo() throws {
        let gitDir = skillsDir.appendingPathComponent(".git")
        guard !FileManager.default.fileExists(atPath: gitDir.path) else { return }

        try git("init", "--initial-branch=main")

        // Create .gitignore
        let gitignore = skillsDir.appendingPathComponent(".gitignore")
        let ignoreContent = ".DS_Store\nThumbs.db\n*.tmp\n*.swp\n*~\n"
        try ignoreContent.write(to: gitignore, atomically: true, encoding: .utf8)

        try git("add", "-A")
        try git("commit", "-m", "Initial skill library snapshot", "--allow-empty")
    }

    // MARK: - Remote

    func setRemote(url: String) throws {
        try ensureRepo()
        let existing = try? git("config", "--get", "remote.origin.url")
        if existing != nil && !existing!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try git("remote", "set-url", "origin", url)
        } else {
            try git("remote", "add", "origin", url)
        }
        // Set upstream tracking
        if let branch = try? git("rev-parse", "--abbrev-ref", "HEAD") {
            let b = branch.trimmingCharacters(in: .whitespacesAndNewlines)
            try? git("branch", "--set-upstream-to=origin/\(b)", b)
        }
    }

    // MARK: - Commit / Push / Pull

    func commitAll(message: String) throws {
        try ensureRepo()
        try git("add", "-A")

        let status = try git("status", "--porcelain")
        guard !status.isEmpty else { throw BackupError.nothingToCommit }

        try git("commit", "-m", message)
    }

    func push() throws {
        try ensureRepo()
        let remote = try? git("config", "--get", "remote.origin.url")
        guard let r = remote, !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BackupError.noRemote
        }

        // Try push; if no upstream, set it
        do {
            try git("push")
        } catch {
            if let branch = try? git("rev-parse", "--abbrev-ref", "HEAD") {
                let b = branch.trimmingCharacters(in: .whitespacesAndNewlines)
                try git("push", "--set-upstream", "origin", b)
            } else {
                throw error
            }
        }

        // Push snapshot tags
        let tags = try git("tag", "--list", "sm-v-*")
        if !tags.isEmpty {
            try? git("push", "origin", "--tags")
        }
    }

    func pull() throws {
        try ensureRepo()
        let remote = try? git("config", "--get", "remote.origin.url")
        guard let r = remote, !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BackupError.noRemote
        }
        try git("pull", "--rebase", "--autostash")
    }

    // MARK: - Clone

    func cloneInto(url: String) throws {
        let fm = FileManager.default
        let backupDir = skillsDir.deletingLastPathComponent().appendingPathComponent("skills-backup-\(Int(Date().timeIntervalSince1970))")

        // Backup existing content
        let hasContent = (try? fm.contentsOfDirectory(atPath: skillsDir.path))?.isEmpty == false
        if hasContent {
            try fm.moveItem(at: skillsDir, to: backupDir)
        }

        do {
            // Clone
            let parent = skillsDir.deletingLastPathComponent()
            let dirName = skillsDir.lastPathComponent
            try runGit(at: parent, args: ["clone", url, dirName])

            // Merge backup if exists
            if hasContent {
                try mergeBackup(from: backupDir, into: skillsDir)
                try? fm.removeItem(at: backupDir)
            }
        } catch {
            // Restore backup on failure
            if hasContent {
                try? fm.removeItem(at: skillsDir)
                try? fm.moveItem(at: backupDir, to: skillsDir)
            }
            throw error
        }
    }

    // MARK: - Snapshots

    func createSnapshot() throws -> String {
        try ensureRepo()

        // Commit any pending changes first
        let status = try git("status", "--porcelain")
        if !status.isEmpty {
            try git("add", "-A")
            try git("commit", "-m", "auto-snapshot before tag")
        }

        // Check if HEAD already has a snapshot tag
        let existing = try git("tag", "--points-at", "HEAD", "--list", "sm-v-*")
        if let first = existing.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first,
           !first.isEmpty {
            return first
        }

        let shortSHA = (try? git("rev-parse", "--short", "HEAD"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0000000"
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        df.timeZone = TimeZone.current
        let tag = "sm-v-\(df.string(from: Date()))-\(shortSHA)"

        try git("tag", "-a", tag, "-m", "Skill library snapshot \(tag)")
        return tag
    }

    func listVersions(limit: Int = 30) throws -> [Version] {
        try ensureRepo()
        let output = try git("tag", "--list", "sm-v-*", "--sort=-creatordate",
                             "--format=%(refname:short)|||%(objectname:short)|||%(creatordate:iso8601)|||%(subject)")
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        var versions: [Version] = []
        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "|||")
            guard parts.count >= 3 else { continue }
            versions.append(Version(
                tag: parts[0].trimmingCharacters(in: .whitespaces),
                commit: parts[1].trimmingCharacters(in: .whitespaces),
                message: parts.count >= 4 ? parts[3].trimmingCharacters(in: .whitespaces) : "",
                committedAt: parts[2].trimmingCharacters(in: .whitespaces)
            ))
            if versions.count >= limit { break }
        }
        return versions
    }

    func restoreVersion(tag: String) throws {
        try ensureRepo()

        // Verify tag exists
        let tagCheck = try git("tag", "--list", tag)
        guard !tagCheck.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BackupError.tagNotFound(tag)
        }

        // Create backup tag at current HEAD
        let backupTag = "sm-restore-backup-\(Int(Date().timeIntervalSince1970))"
        try git("tag", backupTag)

        do {
            try git("read-tree", "--reset", "-u", tag)
            try git("add", "-A")
            try git("commit", "-m", "restore: switch skills library to \(tag)", "--allow-empty")
            // Clean up backup tag on success
            try? git("tag", "-d", backupTag)
        } catch {
            // Rollback on failure
            try? git("read-tree", "--reset", "-u", backupTag)
            try? git("tag", "-d", backupTag)
            throw error
        }
    }

    // MARK: - Helpers

    private func ensureRepo() throws {
        guard FileManager.default.fileExists(atPath: skillsDir.appendingPathComponent(".git").path) else {
            throw BackupError.notARepo
        }
    }

    @discardableResult
    private func git(_ args: String...) throws -> String {
        try runGit(at: skillsDir, args: args)
    }

    @discardableResult
    private func runGit(at dir: URL, args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = dir
        process.environment = ProcessInfo.processInfo.environment

        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe

        try process.run()

        // Timeout: 60s for network ops (push/pull/clone), should be plenty for local ops
        let deadline = Date().addingTimeInterval(60)
        while process.isRunning && Date() < deadline {
            usleep(100_000)
        }
        if process.isRunning {
            process.terminate()
            usleep(500_000)
            let errOutput = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw BackupError.gitFailed(redactURL(errOutput.isEmpty ? "timed out" : errOutput))
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let errOutput = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw BackupError.gitFailed(redactURL(errOutput.isEmpty ? output : errOutput))
        }
        return output
    }

    private func getAheadBehind() -> (Int, Int) {
        guard let revList = try? git("rev-list", "--left-right", "--count", "@{upstream}...HEAD") else {
            return (0, 0)
        }
        let parts = revList.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\t")
        guard parts.count == 2 else { return (0, 0) }
        return (Int(parts[1]) ?? 0, Int(parts[0]) ?? 0)
    }

    private func mergeBackup(from backup: URL, into target: URL) throws {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: backup.path) else { return }
        for item in items where item != ".git" {
            let src = backup.appendingPathComponent(item)
            let dst = target.appendingPathComponent(item)
            if !fm.fileExists(atPath: dst.path) {
                try? fm.copyItem(at: src, to: dst)
            }
        }
    }

    private func redactURL(_ text: String) -> String {
        // Redact user:pass@ from URLs in error messages
        text.replacingOccurrences(
            of: #"://[^@]+@"#,
            with: "://***@",
            options: .regularExpression
        )
    }
}
