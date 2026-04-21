import Foundation

/// Installs skills from local directories or git repositories into the central repo.
final class SkillInstaller {

    struct InstallResult {
        let name: String
        let description: String?
        let centralPath: URL
        let contentHash: String?
    }

    private let centralSkillsDir: URL

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        centralSkillsDir = home.appendingPathComponent(".clawd/skills")
    }

    // MARK: - Local install

    /// Install a skill from a local directory into the central repo.
    func installFromLocal(source: URL, name: String? = nil) throws -> InstallResult {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw InstallerError.sourceNotFound(source.path)
        }

        let skillName = name ?? SkillScanner.inferSkillName(at: source)
        let sanitized = sanitizeSkillName(skillName)
        guard !sanitized.isEmpty else {
            throw InstallerError.invalidName(skillName)
        }

        try FileManager.default.createDirectory(at: centralSkillsDir, withIntermediateDirectories: true)
        let dest = uniqueDestination(parent: centralSkillsDir, name: sanitized, source: source)

        try copySkillDir(src: source, dst: dest)

        let meta = SkillScanner.parseSkillMD(at: dest)
        let hash = SkillScanner.contentHash(of: dest)

        return InstallResult(
            name: meta.name ?? sanitized,
            description: meta.description,
            centralPath: dest,
            contentHash: hash
        )
    }

    // MARK: - Git install

    /// Clone a git repository and install the skill into the central repo.
    func installFromGit(url: String, branch: String? = nil, subpath: String? = nil, name: String? = nil) async throws -> InstallResult {
        let parsed = parseGitSource(url)
        let effectiveBranch = branch ?? parsed.branch
        let effectiveSubpath = subpath ?? parsed.subpath

        let cloneDir = try cloneRepo(url: parsed.cloneURL, branch: effectiveBranch)
        defer { try? FileManager.default.removeItem(at: cloneDir) }

        var skillSource = cloneDir
        if let sub = effectiveSubpath {
            skillSource = cloneDir.appendingPathComponent(sub)
        }

        guard SkillScanner.isValidSkillDir(skillSource) else {
            throw InstallerError.noSkillFound(skillSource.path)
        }

        let result = try installFromLocal(source: skillSource, name: name)

        // Record git revision
        let revision = getHeadRevision(repoDir: cloneDir)

        return InstallResult(
            name: result.name,
            description: result.description,
            centralPath: result.centralPath,
            contentHash: result.contentHash
        )
    }

    /// Clone and install updated skill content to a staging directory, then swap.
    func updateFromGit(url: String, branch: String?, subpath: String?, currentCentralPath: URL) throws -> InstallResult {
        let parsed = parseGitSource(url)
        let effectiveBranch = branch ?? parsed.branch
        let effectiveSubpath = subpath ?? parsed.subpath

        let cloneDir = try cloneRepo(url: parsed.cloneURL, branch: effectiveBranch)
        defer { try? FileManager.default.removeItem(at: cloneDir) }

        var skillSource = cloneDir
        if let sub = effectiveSubpath {
            skillSource = cloneDir.appendingPathComponent(sub)
        }

        guard SkillScanner.isValidSkillDir(skillSource) else {
            throw InstallerError.noSkillFound(skillSource.path)
        }

        let meta = SkillScanner.parseSkillMD(at: skillSource)
        let newHash = SkillScanner.contentHash(of: skillSource)
        let revision = getHeadRevision(repoDir: cloneDir)

        // Stage then swap
        let stagedDir = currentCentralPath.deletingLastPathComponent()
            .appendingPathComponent(".staged_\(UUID().uuidString)")
        try copySkillDir(src: skillSource, dst: stagedDir)
        try swapSkillDirectory(staged: stagedDir, target: currentCentralPath)

        return InstallResult(
            name: meta.name ?? currentCentralPath.lastPathComponent,
            description: meta.description,
            centralPath: currentCentralPath,
            contentHash: newHash
        )
    }

    /// Reimport a local skill from its original source path.
    func reimportLocal(source: URL, currentCentralPath: URL) throws -> InstallResult {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw InstallerError.sourceNotFound(source.path)
        }
        guard SkillScanner.isValidSkillDir(source) else {
            throw InstallerError.noSkillFound(source.path)
        }

        let stagedDir = currentCentralPath.deletingLastPathComponent()
            .appendingPathComponent(".staged_\(UUID().uuidString)")
        try copySkillDir(src: source, dst: stagedDir)
        try swapSkillDirectory(staged: stagedDir, target: currentCentralPath)

        let meta = SkillScanner.parseSkillMD(at: currentCentralPath)
        let hash = SkillScanner.contentHash(of: currentCentralPath)

        return InstallResult(
            name: meta.name ?? currentCentralPath.lastPathComponent,
            description: meta.description,
            centralPath: currentCentralPath,
            contentHash: hash
        )
    }

    // MARK: - Uninstall

    /// Remove a skill from the central repo and all its sync targets.
    func uninstall(centralPath: URL) throws {
        if FileManager.default.fileExists(atPath: centralPath.path) {
            try FileManager.default.removeItem(at: centralPath)
        }
    }

    // MARK: - Git helpers

    struct ParsedGitSource {
        let originalURL: String
        let cloneURL: String
        let branch: String?
        let subpath: String?
    }

    func parseGitSource(_ url: String) -> ParsedGitSource {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        var cloneURL = trimmed
        var branch: String?
        var subpath: String?

        // Handle GitHub tree URLs: github.com/user/repo/tree/branch/subpath
        if let range = trimmed.range(of: #"github\.com/([^/]+/[^/]+)/tree/([^/]+)(/(.+))?"#, options: .regularExpression) {
            let match = String(trimmed[range])
            let parts = trimmed.components(separatedBy: "/tree/")
            if parts.count == 2 {
                cloneURL = parts[0]
                if !cloneURL.hasSuffix(".git") { cloneURL += ".git" }

                let branchAndPath = parts[1]
                if let slashIndex = branchAndPath.firstIndex(of: "/") {
                    branch = String(branchAndPath[..<slashIndex])
                    let sub = String(branchAndPath[branchAndPath.index(after: slashIndex)...])
                    if !sub.isEmpty { subpath = sub }
                } else {
                    branch = branchAndPath
                }
            }
        } else if !trimmed.contains("://") && !trimmed.hasPrefix("git@") && trimmed.contains("/") {
            // Shorthand: user/repo -> https://github.com/user/repo.git
            let components = trimmed.split(separator: "/")
            if components.count >= 2 {
                cloneURL = "https://github.com/\(trimmed)"
                if !cloneURL.hasSuffix(".git") { cloneURL += ".git" }
            }
        }

        return ParsedGitSource(originalURL: trimmed, cloneURL: cloneURL, branch: branch, subpath: subpath)
    }

    private func cloneRepo(url: String, branch: String?) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawd-clone-\(UUID().uuidString)")

        var args = ["clone", "--depth", "1"]
        if let branch = branch {
            args += ["--branch", branch]
        }
        args += [url, tempDir.path]

        let (_, errMsg) = try runGitProcess(args: args, timeout: 60)
        if let err = errMsg {
            throw InstallerError.gitCloneFailed("\(url) — \(err)")
        }

        return tempDir
    }

    /// Resolve the latest remote HEAD SHA without cloning.
    func resolveRemoteRevision(url: String, branch: String?) throws -> String {
        var args = ["ls-remote"]
        args += [url]
        if let branch = branch {
            args += [branch]
        } else {
            args += ["HEAD"]
        }

        let (output, _) = try runGitProcess(args: args, timeout: 30, captureOutput: true)
        guard let out = output,
              let sha = out.split(separator: "\t").first else {
            throw InstallerError.gitLsRemoteFailed(url)
        }
        return String(sha)
    }

    /// Get local HEAD revision for a repo directory.
    func getHeadRevision(repoDir: URL) -> String? {
        guard let (output, _) = try? runGitProcess(args: ["-C", repoDir.path, "rev-parse", "HEAD"], timeout: 5, captureOutput: true) else {
            return nil
        }
        return output?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Git process helper

    /// Run a git process with timeout. Returns (stdout, errorMessage).
    /// Throws if process can't be launched; returns error message string on non-zero exit.
    @discardableResult
    private func runGitProcess(args: [String], timeout: TimeInterval, captureOutput: Bool = false) throws -> (String?, String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment

        let outPipe = captureOutput ? Pipe() : nil
        let errPipe = Pipe()
        process.standardOutput = captureOutput ? outPipe : FileHandle.nullDevice
        process.standardError = errPipe

        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(100_000) // 100ms
        }
        if process.isRunning {
            process.terminate()
            usleep(500_000) // 500ms grace
            if process.isRunning {
                process.interrupt() // SIGINT as stronger signal
            }
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "timed out after \(Int(timeout))s"
            return (nil, errStr.isEmpty ? "timed out after \(Int(timeout))s" : errStr)
        }

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit code \(process.terminationStatus)"
            return (nil, errStr)
        }

        var output: String?
        if captureOutput, let outPipe = outPipe {
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            output = String(data: data, encoding: .utf8)
        }
        return (output, nil)
    }

    // MARK: - File helpers

    /// Atomically swap a staged skill directory with the target.
    private func swapSkillDirectory(staged: URL, target: URL) throws {
        let fm = FileManager.default
        let backup = target.deletingLastPathComponent()
            .appendingPathComponent(".backup_\(UUID().uuidString)")

        if fm.fileExists(atPath: target.path) {
            try fm.moveItem(at: target, to: backup)
        }
        do {
            try fm.moveItem(at: staged, to: target)
            // Clean up backup
            if fm.fileExists(atPath: backup.path) {
                try? fm.removeItem(at: backup)
            }
        } catch {
            // Restore backup on failure
            if fm.fileExists(atPath: backup.path) {
                try? fm.moveItem(at: backup, to: target)
            }
            throw error
        }
    }

    private func copySkillDir(src: URL, dst: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)

        let contents = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])
        for item in contents {
            let name = item.lastPathComponent
            if name == ".git" || name == ".DS_Store" { continue }

            // Skip symlinks for security
            let resourceValues = try item.resourceValues(forKeys: [.isSymbolicLinkKey])
            if resourceValues.isSymbolicLink == true { continue }

            let dest = dst.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                try copySkillDir(src: item, dst: dest)
            } else {
                try fm.copyItem(at: item, to: dest)
            }
        }
    }

    private func uniqueDestination(parent: URL, name: String, source: URL) -> URL {
        let fm = FileManager.default
        let sourceHash = SkillScanner.contentHash(of: source)

        for i in 1...100 {
            let candidate = i == 1 ? parent.appendingPathComponent(name)
                                   : parent.appendingPathComponent("\(name)-\(i)")
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            if let sourceHash = sourceHash, SkillScanner.contentHash(of: candidate) == sourceHash {
                return candidate
            }
        }
        return parent.appendingPathComponent(name)
    }

    private func sanitizeSkillName(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
        guard last != ".." && last != "." && !last.isEmpty else { return "" }

        var sanitized = last
        let invalid = CharacterSet(charactersIn: #"<>:"/\|?*"#).union(.controlCharacters)
        sanitized = sanitized.unicodeScalars.map { invalid.contains($0) ? "_" : String($0) }.joined()
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return sanitized
    }
}

// MARK: - Errors

enum InstallerError: LocalizedError {
    case sourceNotFound(String)
    case invalidName(String)
    case noSkillFound(String)
    case gitCloneFailed(String)
    case gitLsRemoteFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceNotFound(let p): return "Source not found: \(p)"
        case .invalidName(let n): return "Invalid skill name: \(n)"
        case .noSkillFound(let p): return "No SKILL.md found at: \(p)"
        case .gitCloneFailed(let url): return "Git clone failed: \(url)"
        case .gitLsRemoteFailed(let url): return "Git ls-remote failed: \(url)"
        }
    }
}
