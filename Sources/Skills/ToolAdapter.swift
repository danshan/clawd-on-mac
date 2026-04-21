import Foundation

enum SyncMode: String, Codable {
    case symlink
    case copy
}

struct ToolAdapter: Codable {
    let key: String
    let displayName: String
    let relativeSkillsDir: String
    let relativeDetectDir: String
    let additionalScanDirs: [String]
    let overrideSkillsDir: String?
    let isCustom: Bool
    let recursiveScan: Bool

    private static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    private static func candidatePaths(relative: String) -> [URL] {
        var candidates = [home.appendingPathComponent(relative)]
        if relative.hasPrefix(".config/") {
            let suffix = String(relative.dropFirst(".config/".count))
            let configDir = home.appendingPathComponent("Library/Application Support")
            let configPath = configDir.appendingPathComponent(suffix)
            if !candidates.contains(configPath) {
                candidates.append(configPath)
            }
        }
        return candidates
    }

    private static func selectExistingOrDefault(_ paths: [URL]) -> URL {
        paths.first { FileManager.default.fileExists(atPath: $0.path) } ?? paths[0]
    }

    func skillsDir() -> URL {
        if let abs = overrideSkillsDir {
            return URL(fileURLWithPath: abs)
        }
        return Self.selectExistingOrDefault(Self.candidatePaths(relative: relativeSkillsDir))
    }

    func isInstalled() -> Bool {
        if isCustom || overrideSkillsDir != nil { return true }
        return Self.candidatePaths(relative: relativeDetectDir)
            .contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    func allScanDirs() -> [URL] {
        var dirs = [skillsDir()]
        for rel in additionalScanDirs {
            for candidate in Self.candidatePaths(relative: rel) {
                if FileManager.default.fileExists(atPath: candidate.path), !dirs.contains(candidate) {
                    dirs.append(candidate)
                }
            }
        }
        return dirs
    }

    /// Default sync mode: always symlink for global tool directories
    var defaultSyncMode: SyncMode {
        .symlink
    }

    // MARK: - Built-in adapters

    static func builtinAdapters() -> [ToolAdapter] {
        let simple: [(String, String, String, String)] = [
            ("cursor",         "Cursor",           ".cursor/skills",               ".cursor"),
            ("claude_code",    "Claude Code",       ".claude/skills",              ".claude"),
            ("codex",          "Codex",             ".codex/skills",               ".codex"),
            ("opencode",       "OpenCode",          ".config/opencode/skills",     ".config/opencode"),
            ("antigravity",    "Antigravity",       ".gemini/antigravity/skills",  ".gemini/antigravity"),
            ("amp",            "Amp",               ".config/agents/skills",       ".config/agents"),
            ("kilo_code",      "Kilo Code",         ".kilocode/skills",            ".kilocode"),
            ("roo_code",       "Roo Code",          ".roo/skills",                 ".roo"),
            ("goose",          "Goose",             ".config/goose/skills",        ".config/goose"),
            ("gemini_cli",     "Gemini CLI",        ".gemini/skills",              ".gemini"),
            ("github_copilot", "GitHub Copilot",    ".copilot/skills",             ".copilot"),
            ("openclaw",       "OpenClaw",          ".openclaw/skills",            ".openclaw"),
            ("droid",          "Droid",             ".factory/skills",             ".factory"),
            ("windsurf",       "Windsurf",          ".codeium/windsurf/skills",    ".codeium/windsurf"),
            ("trae",           "TRAE IDE",          ".trae/skills",                ".trae"),
            ("cline",          "Cline",             ".agents/skills",              ".cline"),
            ("deepagents",     "Deep Agents",       ".deepagents/agent/skills",    ".deepagents"),
            ("firebender",     "Firebender",        ".firebender/skills",          ".firebender"),
            ("kimi",           "Kimi Code CLI",     ".config/agents/skills",       ".kimi"),
            ("replit",         "Replit",             ".config/agents/skills",       ".replit"),
            ("warp",           "Warp",              ".agents/skills",              ".warp"),
            ("augment",        "Augment",           ".augment/skills",             ".augment"),
            ("bob",            "IBM Bob",           ".bob/skills",                 ".bob"),
            ("codebuddy",      "CodeBuddy",         ".codebuddy/skills",           ".codebuddy"),
            ("command_code",   "Command Code",      ".commandcode/skills",         ".commandcode"),
            ("continue",       "Continue",          ".continue/skills",            ".continue"),
            ("cortex",         "Cortex Code",       ".snowflake/cortex/skills",    ".snowflake/cortex"),
            ("crush",          "Crush",             ".config/crush/skills",        ".config/crush"),
            ("iflow",          "iFlow CLI",         ".iflow/skills",               ".iflow"),
            ("junie",          "Junie",             ".junie/skills",               ".junie"),
            ("kiro",           "Kiro CLI",          ".kiro/skills",                ".kiro"),
            ("kode",           "Kode",              ".kode/skills",                ".kode"),
            ("mcpjam",         "MCPJam",            ".mcpjam/skills",              ".mcpjam"),
            ("mistral_vibe",   "Mistral Vibe",      ".vibe/skills",                ".vibe"),
            ("mux",            "Mux",               ".mux/skills",                 ".mux"),
            ("neovate",        "Neovate",           ".neovate/skills",             ".neovate"),
            ("openhands",      "OpenHands",         ".openhands/skills",           ".openhands"),
            ("pi",             "Pi",                ".pi/agent/skills",            ".pi/agent"),
            ("pochi",          "Pochi",             ".pochi/skills",               ".pochi"),
            ("qoder",          "Qoder",             ".qoder/skills",               ".qoder"),
            ("qwen_code",      "Qwen Code",         ".qwen/skills",                ".qwen"),
            ("trae_cn",        "TRAE CN",           ".trae-cn/skills",             ".trae-cn"),
            ("zencoder",       "Zencoder",          ".zencoder/skills",            ".zencoder"),
            ("adal",           "AdaL",              ".adal/skills",                ".adal"),
        ]

        var adapters = simple.map { (key, name, skillsDir, detectDir) in
            ToolAdapter(
                key: key, displayName: name,
                relativeSkillsDir: skillsDir, relativeDetectDir: detectDir,
                additionalScanDirs: [], overrideSkillsDir: nil,
                isCustom: false, recursiveScan: false
            )
        }

        // Hermes has recursive scan
        adapters.append(ToolAdapter(
            key: "hermes", displayName: "Hermes Agent",
            relativeSkillsDir: ".hermes/skills", relativeDetectDir: ".hermes",
            additionalScanDirs: [], overrideSkillsDir: nil,
            isCustom: false, recursiveScan: true
        ))

        return adapters
    }

    static func findAdapter(key: String) -> ToolAdapter? {
        builtinAdapters().first { $0.key == key }
    }

    // MARK: - Database-aware adapters (merges builtin + custom + overrides + disabled)

    struct CustomToolDef: Codable {
        let key: String
        let displayName: String
        let skillsDir: String
        let projectRelativeSkillsDir: String?
    }

    /// Load all adapters with database overrides applied.
    static func allAdapters(db: SkillDatabase) throws -> [ToolAdapter] {
        let disabledKeys = try loadDisabledTools(db: db)
        let pathOverrides = try loadCustomToolPaths(db: db)
        let customDefs = try loadCustomTools(db: db)

        var adapters = builtinAdapters().filter { !disabledKeys.contains($0.key) }

        // Apply path overrides
        adapters = adapters.map { adapter in
            guard let override = pathOverrides[adapter.key] else { return adapter }
            return ToolAdapter(
                key: adapter.key, displayName: adapter.displayName,
                relativeSkillsDir: adapter.relativeSkillsDir, relativeDetectDir: adapter.relativeDetectDir,
                additionalScanDirs: adapter.additionalScanDirs, overrideSkillsDir: override,
                isCustom: adapter.isCustom, recursiveScan: adapter.recursiveScan
            )
        }

        // Add custom tools
        for def in customDefs where !disabledKeys.contains(def.key) {
            adapters.append(ToolAdapter(
                key: def.key, displayName: def.displayName,
                relativeSkillsDir: "", relativeDetectDir: "",
                additionalScanDirs: [], overrideSkillsDir: def.skillsDir,
                isCustom: true, recursiveScan: false
            ))
        }

        return adapters
    }

    /// Find a single adapter with database overrides.
    static func findAdapter(key: String, db: SkillDatabase) throws -> ToolAdapter? {
        try allAdapters(db: db).first { $0.key == key }
    }

    /// Find adapter including disabled tools (for sync operations).
    static func findAdapterIncludingDisabled(key: String, db: SkillDatabase) throws -> ToolAdapter? {
        let pathOverrides = try loadCustomToolPaths(db: db)
        let customDefs = try loadCustomTools(db: db)

        // Check builtins first
        var adapter = builtinAdapters().first { $0.key == key }
        if adapter == nil {
            // Check custom tools
            if let def = customDefs.first(where: { $0.key == key }) {
                adapter = ToolAdapter(
                    key: def.key, displayName: def.displayName,
                    relativeSkillsDir: "", relativeDetectDir: "",
                    additionalScanDirs: [], overrideSkillsDir: def.skillsDir,
                    isCustom: true, recursiveScan: false
                )
            }
        }
        // Apply path override
        if let a = adapter, let override = pathOverrides[a.key] {
            return ToolAdapter(
                key: a.key, displayName: a.displayName,
                relativeSkillsDir: a.relativeSkillsDir, relativeDetectDir: a.relativeDetectDir,
                additionalScanDirs: a.additionalScanDirs, overrideSkillsDir: override,
                isCustom: a.isCustom, recursiveScan: a.recursiveScan
            )
        }
        return adapter
    }

    // MARK: - Settings persistence

    static func loadDisabledTools(db: SkillDatabase) throws -> Set<String> {
        guard let json = try db.getSetting("disabled_tools"),
              let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(arr)
    }

    static func saveDisabledTools(_ keys: Set<String>, db: SkillDatabase) throws {
        let data = try JSONEncoder().encode(Array(keys))
        try db.setSetting("disabled_tools", value: String(data: data, encoding: .utf8))
    }

    static func loadCustomToolPaths(db: SkillDatabase) throws -> [String: String] {
        guard let json = try db.getSetting("custom_tool_paths"),
              let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    static func saveCustomToolPaths(_ paths: [String: String], db: SkillDatabase) throws {
        let data = try JSONEncoder().encode(paths)
        try db.setSetting("custom_tool_paths", value: String(data: data, encoding: .utf8))
    }

    static func loadCustomTools(db: SkillDatabase) throws -> [CustomToolDef] {
        guard let json = try db.getSetting("custom_tools"),
              let data = json.data(using: .utf8),
              let defs = try? JSONDecoder().decode([CustomToolDef].self, from: data) else { return [] }
        return defs
    }

    static func saveCustomTools(_ tools: [CustomToolDef], db: SkillDatabase) throws {
        let data = try JSONEncoder().encode(tools)
        try db.setSetting("custom_tools", value: String(data: data, encoding: .utf8))
    }
}
