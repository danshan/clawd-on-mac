import Foundation
import CommonCrypto

/// Parses SKILL.md frontmatter and discovers unmanaged skills across tool directories.
final class SkillScanner {

    struct SkillMeta {
        let name: String?
        let description: String?
    }

    struct ScanResult {
        let toolsScanned: Int
        let skillsFound: Int
        let discovered: [DiscoveredSkillRecord]
    }

    private static let skillMarkers = ["SKILL.md", "skill.md"]
    private static let recursiveScanSkipDirs: Set<String> = [".hub", ".git", "node_modules"]

    // MARK: - SKILL.md parsing

    static func parseSkillMD(at dir: URL) -> SkillMeta {
        for marker in skillMarkers {
            let file = dir.appendingPathComponent(marker)
            if let content = try? String(contentsOf: file, encoding: .utf8) {
                return parseFrontmatter(content)
            }
        }
        return SkillMeta(name: nil, description: nil)
    }

    /// Convenience: parse metadata from a path string
    static func parseSkillMetadata(at path: String) -> SkillMeta {
        return parseSkillMD(at: URL(fileURLWithPath: path))
    }

    static func isValidSkillDir(_ dir: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return false }
        return skillMarkers.contains { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    /// Infer a skill name: prefer frontmatter, fall back to directory name.
    static func inferSkillName(at dir: URL) -> String {
        parseSkillMD(at: dir).name ?? dir.lastPathComponent
    }

    // MARK: - Content hash (SHA256 of all files)

    static func contentHash(of dir: URL) -> String? {
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return nil
        }

        var paths: [String] = []
        while let url = enumerator.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                paths.append(url.path)
            }
        }
        paths.sort()

        var ctx = CC_SHA256_CTX()
        CC_SHA256_Init(&ctx)
        for path in paths {
            if let data = FileManager.default.contents(atPath: path) {
                data.withUnsafeBytes { buf in
                    _ = CC_SHA256_Update(&ctx, buf.baseAddress, CC_LONG(data.count))
                }
            }
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &ctx)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Discovery scanning

    /// Scan all installed tools for unmanaged skills.
    func scanLocalSkills(managedPaths: [String], adapters: [ToolAdapter]) -> ScanResult {
        var discovered: [DiscoveredSkillRecord] = []
        var toolsScanned = 0

        for adapter in adapters where adapter.isInstalled() {
            toolsScanned += 1

            let primaryDir = adapter.skillsDir()
            if FileManager.default.fileExists(atPath: primaryDir.path) {
                if adapter.recursiveScan {
                    scanRecursive(adapterKey: adapter.key, dir: primaryDir, managedPaths: managedPaths, discovered: &discovered)
                } else {
                    scanFlat(adapterKey: adapter.key, dir: primaryDir, managedPaths: managedPaths, discovered: &discovered)
                }
            }

            // Additional scan dirs
            for scanDir in adapter.allScanDirs().dropFirst() {
                scanFlat(adapterKey: adapter.key, dir: scanDir, managedPaths: managedPaths, discovered: &discovered)
            }
        }

        return ScanResult(toolsScanned: toolsScanned, skillsFound: discovered.count, discovered: discovered)
    }

    // MARK: - Private scanning

    private let centralDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".clawd/skills")
    }()

    private func isSymlinkToCentral(_ path: URL) -> Bool {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path.path) else {
            return false
        }
        let centralPrefix = centralDir.path.hasSuffix("/") ? centralDir.path : centralDir.path + "/"
        let resolvedDest = URL(fileURLWithPath: dest).resolvingSymlinksInPath().path
        return resolvedDest.hasPrefix(centralPrefix) || resolvedDest == centralDir.resolvingSymlinksInPath().path
    }

    private func scanFlat(adapterKey: String, dir: URL, managedPaths: [String], discovered: inout [DiscoveredSkillRecord]) {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return }

        for entry in entries {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard !isSymlinkToCentral(entry), Self.isValidSkillDir(entry) else { continue }

            pushDiscovered(adapterKey: adapterKey, path: entry, managedPaths: managedPaths, discovered: &discovered)
        }
    }

    private func scanRecursive(adapterKey: String, dir: URL, managedPaths: [String], discovered: inout [DiscoveredSkillRecord]) {
        var skillDirs: [URL] = []
        var visited = Set<String>()
        collectSkillDirsRecursive(dir: dir, visited: &visited, results: &skillDirs)

        for path in skillDirs {
            pushDiscovered(adapterKey: adapterKey, path: path, managedPaths: managedPaths, discovered: &discovered)
        }
    }

    private func collectSkillDirsRecursive(dir: URL, visited: inout Set<String>, results: inout [URL]) {
        let canonical = dir.resolvingSymlinksInPath().path
        guard visited.insert(canonical).inserted else { return }

        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return }

        for entry in entries {
            let name = entry.lastPathComponent
            guard !Self.recursiveScanSkipDirs.contains(name) else { continue }

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard !isSymlinkToCentral(entry) else { continue }

            if Self.isValidSkillDir(entry) {
                results.append(entry)
                continue  // don't descend into skill dirs
            }
            collectSkillDirsRecursive(dir: entry, visited: &visited, results: &results)
        }
    }

    private func pushDiscovered(adapterKey: String, path: URL, managedPaths: [String], discovered: inout [DiscoveredSkillRecord]) {
        let pathStr = path.path
        guard !managedPaths.contains(pathStr) else { return }

        let name = Self.inferSkillName(at: path)
        let fingerprint = Self.contentHash(of: path)
        let foundAt = (try? FileManager.default.attributesOfItem(atPath: pathStr)[.modificationDate] as? Date)
            .map { Int64($0.timeIntervalSince1970 * 1000) }
            ?? Int64(Date().timeIntervalSince1970 * 1000)

        discovered.append(DiscoveredSkillRecord(
            id: UUID().uuidString,
            tool: adapterKey,
            foundPath: pathStr,
            nameGuess: name,
            fingerprint: fingerprint,
            foundAt: foundAt,
            importedSkillId: nil
        ))
    }

    // MARK: - Frontmatter parser

    private static func parseFrontmatter(_ content: String) -> SkillMeta {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else {
            return SkillMeta(name: nil, description: nil)
        }

        let rest = String(trimmed.dropFirst(3))
        guard let endIndex = rest.range(of: "---")?.lowerBound else {
            return SkillMeta(name: nil, description: nil)
        }

        let yaml = String(rest[..<endIndex])
        let lines = yaml.components(separatedBy: "\n")

        var name: String?
        var description: String?
        var idx = 0

        while idx < lines.count {
            let line = lines[idx]
            let stripped = line.trimmingCharacters(in: .whitespaces)

            if stripped.hasPrefix("name:") {
                name = extractYAMLScalar(lines: lines, index: &idx, key: "name")
            } else if stripped.hasPrefix("description:") {
                description = extractYAMLScalar(lines: lines, index: &idx, key: "description")
            } else {
                idx += 1
            }
        }

        return SkillMeta(name: name, description: description)
    }

    /// Parse a YAML scalar value supporting single-line, block scalars (> and |), and multiline quoted strings.
    private static func extractYAMLScalar(lines: [String], index: inout Int, key: String) -> String? {
        let line = lines[index]
        let stripped = line.trimmingCharacters(in: .whitespaces)
        let afterKey = String(stripped.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        index += 1

        // Block scalar: > (folded) or | (literal)
        if afterKey == ">" || afterKey == "|" {
            let fold = (afterKey == ">")
            var parts: [String] = []
            while index < lines.count {
                let next = lines[index]
                // Continuation lines must be indented (at least one leading space/tab)
                guard !next.isEmpty, next.first == " " || next.first == "\t" else { break }
                // Stop if it looks like a new top-level key
                let trimNext = next.trimmingCharacters(in: .whitespaces)
                if trimNext.contains(":") && !trimNext.hasPrefix("-") && trimNext.first?.isLetter == true {
                    let colonIdx = trimNext.firstIndex(of: ":")!
                    let beforeColon = trimNext[trimNext.startIndex..<colonIdx]
                    if beforeColon.allSatisfy({ $0.isLetter || $0 == "_" || $0 == "-" }) {
                        break
                    }
                }
                parts.append(trimNext)
                index += 1
            }
            let joined = fold
                ? parts.joined(separator: " ")
                : parts.joined(separator: "\n")
            return joined.isEmpty ? nil : joined
        }

        // Multiline quoted string: starts with " but doesn't end with "
        if afterKey.hasPrefix("\"") && !afterKey.hasSuffix("\"") {
            var accumulated = String(afterKey.dropFirst())
            while index < lines.count {
                let next = lines[index]
                index += 1
                let trimmed = next.trimmingCharacters(in: .whitespaces)
                if trimmed.hasSuffix("\"") {
                    accumulated += " " + String(trimmed.dropLast())
                    break
                }
                accumulated += " " + trimmed
            }
            return accumulated.isEmpty ? nil : accumulated
        }

        // Single-line: strip surrounding quotes
        if (afterKey.hasPrefix("\"") && afterKey.hasSuffix("\"")) ||
           (afterKey.hasPrefix("'") && afterKey.hasSuffix("'")) {
            let inner = String(afterKey.dropFirst().dropLast())
            return inner.isEmpty ? nil : inner
        }
        return afterKey.isEmpty ? nil : afterKey
    }
}
