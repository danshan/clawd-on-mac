import Foundation

struct SkillInfo: Codable {
    let name: String
    let description: String
}

struct ToolInfo: Codable {
    let id: String
    let name: String
    let version: String?
    let icon: String
    let modelName: String?
    let apiEndpoint: String?
    let authType: String?
    let reasoningLevel: String?
    let subscription: String?
    let plugins: [String]
    let mcpServers: [String]
    let skills: [String]
    let skillDetails: [SkillInfo]
    let hookIntegrated: Bool
    let configPath: String?
    let quota: [String: String]
    let details: [String: String]
}

class ToolScanner {

    static func scan() -> [ToolInfo] {
        var tools: [ToolInfo] = []
        if let t = scanClaudeCode()  { tools.append(t) }
        if let t = scanGeminiCLI()   { tools.append(t) }
        if let t = scanCodexCLI()    { tools.append(t) }
        if let t = scanOpenCode()    { tools.append(t) }
        if let t = scanCopilotCLI()  { tools.append(t) }
        if let t = scanCursor()      { tools.append(t) }
        if let t = scanKiro()        { tools.append(t) }
        if let t = scanPi()          { tools.append(t) }
        return tools
    }

    // MARK: - Claude Code

    private static func scanClaudeCode() -> ToolInfo? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configDir = "\(home)/.claude"
        guard FileManager.default.fileExists(atPath: configDir) else { return nil }

        let version = extractVersion(resolveAndRun("claude", extraPaths: ["\(home)/.claude/local/bin"], args: ["--version"]))

        let settingsPath = "\(configDir)/settings.json"
        let settings = readJSON(settingsPath) as? [String: Any]

        var model: String?
        var apiEndpoint: String?
        var authType: String?
        var plugins: [String] = []
        var hookCount = 0
        var reasoningLevel: String?
        var details: [String: String] = [:]

        var mcpServers: [String] = []
        var quota: [String: String] = [:]

        if let s = settings {
            // Read model and API config from settings.json env section
            if let env = s["env"] as? [String: String] {
                model = env["CLAUDE_MODEL"] ?? env["ANTHROPIC_MODEL"]
                apiEndpoint = env["ANTHROPIC_BASE_URL"] ?? env["CLAUDE_API_BASE"]
                if env["ANTHROPIC_AUTH_TOKEN"] != nil || env["ANTHROPIC_API_KEY"] != nil {
                    authType = "API Key"
                }
                // Detect provider from endpoint for quota context
                if let ep = apiEndpoint {
                    if ep.contains("anthropic.com") { quota["provider"] = "Anthropic" }
                    else if ep.contains("minimax") { quota["provider"] = "MiniMax" }
                    else if ep.contains("openrouter") { quota["provider"] = "OpenRouter" }
                    else if ep.contains("bedrock") { quota["provider"] = "AWS Bedrock" }
                    else if ep.contains("vertex") { quota["provider"] = "Google Vertex" }
                    else { quota["provider"] = URL(string: ep)?.host ?? ep }
                }
            }
            if let perms = s["permissions"] as? [String: Any] {
                if let allow = perms["allow"] as? [String] {
                    plugins = allow
                }
            }
            if let hooks = s["hooks"] as? [String: Any] {
                hookCount = hooks.count
                details["hooks"] = "\(hookCount) hook event(s)"
            }
            if let ep = s["enabledPlugins"] as? [String], !ep.isEmpty {
                details["plugins"] = ep.joined(separator: ", ")
            }
            if let mcp = s["mcpServers"] as? [String: Any] {
                mcpServers = Array(mcp.keys).sorted()
            }
        }

        // Also check for project-level settings
        let projectSettingsPath = "\(configDir)/projects"
        if FileManager.default.fileExists(atPath: projectSettingsPath) {
            details["project_configs"] = "yes"
        }

        // Detect clawd hook integration from hooks in settings.json
        var hookIntegrated = false
        if let s = settings, let hooks = s["hooks"] as? [String: Any] {
            let hooksJSON = String(data: (try? JSONSerialization.data(withJSONObject: hooks)) ?? Data(), encoding: .utf8) ?? ""
            hookIntegrated = hooksJSON.localizedCaseInsensitiveContains("clawd")
        }

        // Scan skills directory
        let skillsDir = "\(configDir)/skills"
        let skillDetails = scanSkillsDirectory(skillsDir)

        return ToolInfo(
            id: "claude-code",
            name: "Claude Code",
            version: version,
            icon: "\u{1F9E0}",
            modelName: model,
            apiEndpoint: apiEndpoint,
            authType: authType,
            reasoningLevel: reasoningLevel,
            subscription: nil,
            plugins: plugins,
            mcpServers: mcpServers,
            skills: skillDetails.map { $0.name },
            skillDetails: skillDetails,
            hookIntegrated: hookIntegrated,
            configPath: settingsPath,
            quota: quota,
            details: details
        )
    }

    // MARK: - Gemini CLI

    private static func scanGeminiCLI() -> ToolInfo? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configDir = "\(home)/.gemini"
        guard FileManager.default.fileExists(atPath: configDir) else { return nil }

        let version = extractVersion(resolveAndRun("gemini", args: ["--version"]))

        let settingsPath = "\(configDir)/settings.json"
        let settings = readJSON(settingsPath) as? [String: Any]

        var model: String?
        var details: [String: String] = [:]
        var hookIntegrated = false
        var mcpServers: [String] = []

        if let s = settings {
            if let m = s["model"] as? String { model = m }
            if let general = s["general"] as? [String: Any] {
                if let m = general["model"] as? String { model = m }
            }
            if let theme = s["theme"] as? String { details["theme"] = theme }
            if let exp = s["experimental"] as? [String: Any] {
                let features = exp.filter { ($0.value as? Bool) == true }.map { $0.key }
                if !features.isEmpty { details["experimental"] = features.joined(separator: ", ") }
            }
            if let hooks = s["hooks"] as? [String: Any] {
                details["hooks"] = "\(hooks.count) hook event(s)"
                for (_, hookList) in hooks {
                    if let arr = hookList as? [[String: Any]] {
                        for h in arr {
                            if let name = h["name"] as? String, name == "clawd" {
                                hookIntegrated = true
                            }
                        }
                    }
                }
            }
            if let mcp = s["mcpServers"] as? [String: Any] {
                mcpServers = Array(mcp.keys).sorted()
            }
        }

        // Check Google account for auth type and quota
        let oauthPath = "\(configDir)/oauth_creds.json"
        let hasOAuth = FileManager.default.fileExists(atPath: oauthPath)
        var quota: [String: String] = [:]
        if hasOAuth {
            quota["provider"] = "Google Cloud"
            // Extract account name from id_token JWT
            if let oauthData = readJSON(oauthPath) as? [String: Any],
               let idToken = oauthData["id_token"] as? String {
                let claims = Self.parseJWTClaims(idToken)
                if let name = claims["name"] as? String {
                    quota["account"] = name
                }
            }
        }

        // Scan skills from extensions directories
        var allSkillDetails: [SkillInfo] = []
        let extensionsDir = "\(configDir)/extensions"
        if let extensions = try? FileManager.default.contentsOfDirectory(atPath: extensionsDir) {
            for ext in extensions {
                let extSkillsDir = "\(extensionsDir)/\(ext)/skills"
                allSkillDetails.append(contentsOf: scanSkillsDirectory(extSkillsDir))
            }
        }

        return ToolInfo(
            id: "gemini-cli",
            name: "Gemini CLI",
            version: version,
            icon: "\u{2728}",
            modelName: model,
            apiEndpoint: nil,
            authType: hasOAuth ? "OAuth (Google)" : nil,
            reasoningLevel: nil,
            subscription: nil,
            plugins: [],
            mcpServers: mcpServers,
            skills: allSkillDetails.map { $0.name },
            skillDetails: allSkillDetails,
            hookIntegrated: hookIntegrated,
            configPath: settingsPath,
            quota: quota,
            details: details
        )
    }

    // MARK: - Codex CLI

    private static func scanCodexCLI() -> ToolInfo? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configDir = "\(home)/.codex"
        guard FileManager.default.fileExists(atPath: configDir) else { return nil }

        let version = extractVersion(resolveAndRun("codex", args: ["--version"]))

        let configPath = "\(configDir)/config.toml"
        let tomlContent = try? String(contentsOfFile: configPath, encoding: .utf8)

        var model: String?
        var reasoningLevel: String?
        var details: [String: String] = [:]

        var plugins: [String] = []
        var mcpServers: [String] = []
        var skills: [String] = []

        if let toml = tomlContent {
            model = extractTOMLValue(toml, key: "model")
            if let personality = extractTOMLValue(toml, key: "personality") {
                details["personality"] = personality
            }
            if let approval = extractTOMLValue(toml, key: "approval_policy") {
                details["approval_policy"] = approval
            }
            // Extract enabled plugins
            let pluginRegex = try? NSRegularExpression(pattern: #"\[plugins\."([^"]+)"\][\s\S]*?enabled\s*=\s*true"#)
            if let regex = pluginRegex {
                let matches = regex.matches(in: toml, range: NSRange(toml.startIndex..., in: toml))
                plugins = matches.compactMap { match in
                    guard let range = Range(match.range(at: 1), in: toml) else { return nil }
                    return String(toml[range])
                }
            }
            // Extract MCP servers
            let mcpRegex = try? NSRegularExpression(pattern: #"\[mcp_servers\.([^\]]+)\]"#)
            if let regex = mcpRegex {
                let matches = regex.matches(in: toml, range: NSRange(toml.startIndex..., in: toml))
                mcpServers = matches.compactMap { match in
                    guard let range = Range(match.range(at: 1), in: toml) else { return nil }
                    return String(toml[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            }
            // Extract skills
            let skillRegex = try? NSRegularExpression(pattern: #"name\s*=\s*"([^"]+)""#)
            if let regex = skillRegex {
                let matches = regex.matches(in: toml, range: NSRange(toml.startIndex..., in: toml))
                skills = matches.compactMap { match in
                    guard let range = Range(match.range(at: 1), in: toml) else { return nil }
                    return String(toml[range])
                }
            }
        }

        // Auth info
        var authType: String?
        var subscription: String?
        let authPath = "\(configDir)/auth.json"
        if let authData = readJSON(authPath) as? [String: Any] {
            authType = authData["auth_mode"] as? String
            subscription = authData["subscription"] as? String
        }

        // Models cache — new format has { models: [...] }
        let modelsPath = "\(configDir)/models_cache.json"
        if let modelsRoot = readJSON(modelsPath) as? [String: Any],
           let modelsData = modelsRoot["models"] as? [[String: Any]] {
            let modelNames = modelsData.compactMap { $0["slug"] as? String ?? $0["id"] as? String }
            if !modelNames.isEmpty {
                details["available_models"] = modelNames.prefix(5).joined(separator: ", ")
            }
            // Use first model from cache as default when config.toml has no model field
            let targetModel = model ?? modelNames.first
            if model == nil { model = targetModel }
            if let target = targetModel {
                for m in modelsData {
                    let slug = m["slug"] as? String ?? m["id"] as? String
                    if slug == target {
                        if let rl = m["default_reasoning_level"] as? String {
                            reasoningLevel = rl
                        }
                    }
                }
            }
        } else if let modelsData = readJSON(modelsPath) as? [[String: Any]] {
            // Legacy format: array directly
            let modelNames = modelsData.compactMap { $0["id"] as? String }
            if !modelNames.isEmpty {
                details["available_models"] = modelNames.prefix(5).joined(separator: ", ")
            }
        }

        // Quota from JWT id_token
        var quota: [String: String] = [:]
        if let authData = readJSON(authPath) as? [String: Any] {
            // Try top-level first (current format), then nested tokens
            let idToken = authData["id_token"] as? String
                ?? (authData["tokens"] as? [String: Any])?["id_token"] as? String
            if let idToken = idToken {
                quota = Self.parseJWTQuota(idToken)
            }
        }

        // Scan skills directories (~/.codex/skills + ~/.agents/skills)
        let codexSkillsDir = "\(configDir)/skills"
        let agentsSkillsDir = "\(home)/.agents/skills"
        var skillDetails = scanSkillsDirectory(codexSkillsDir)
        let agentSkills = scanSkillsDirectory(agentsSkillsDir)
        // Merge, avoiding duplicates by name
        let existingNames = Set(skillDetails.map { $0.name })
        for s in agentSkills where !existingNames.contains(s.name) {
            skillDetails.append(s)
        }
        // Also include TOML-defined skills not found in directories
        let dirNames = Set(skillDetails.map { $0.name })
        for s in skills where !dirNames.contains(s) {
            skillDetails.append(SkillInfo(name: s, description: ""))
        }

        return ToolInfo(
            id: "codex-cli",
            name: "Codex CLI",
            version: version,
            icon: "\u{1F4BB}",
            modelName: model,
            apiEndpoint: nil,
            authType: authType,
            reasoningLevel: reasoningLevel,
            subscription: subscription,
            plugins: plugins,
            mcpServers: mcpServers,
            skills: skillDetails.map { $0.name },
            skillDetails: skillDetails,
            hookIntegrated: false,
            configPath: configPath,
            quota: quota,
            details: details
        )
    }

    private static func scanOpenCode() -> ToolInfo? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configDir = "\(home)/.opencode"
        let altConfigDir = "\(home)/.config/opencode"
        guard FileManager.default.fileExists(atPath: configDir)
            || FileManager.default.fileExists(atPath: altConfigDir) else { return nil }

        let version = extractVersion(resolveAndRun("opencode",
            extraPaths: ["\(configDir)/bin"], args: ["--version"]))

        var details: [String: String] = [:]
        var plugins: [String] = []

        // Check .config/opencode for rich config
        let settingsPath = "\(altConfigDir)/config.json"
        if let config = readJSON(settingsPath) as? [String: Any] {
            if let pluginArr = config["plugin"] as? [String] {
                plugins = pluginArr.map { URL(string: $0)?.lastPathComponent ?? $0 }
            }
        }

        // Scan skills with descriptions
        let skillDir = "\(altConfigDir)/skills"
        let skillDetails = scanSkillsDirectory(skillDir)
        let skills = skillDetails.map { $0.name }

        return ToolInfo(
            id: "opencode",
            name: "OpenCode",
            version: version,
            icon: "\u{1F310}",
            modelName: nil,
            apiEndpoint: nil,
            authType: nil,
            reasoningLevel: nil,
            subscription: nil,
            plugins: plugins,
            mcpServers: [],
            skills: skills,
            skillDetails: skillDetails,
            hookIntegrated: false,
            configPath: FileManager.default.fileExists(atPath: altConfigDir) ? altConfigDir : configDir,
            quota: [:],
            details: details
        )
    }

    // MARK: - GitHub Copilot CLI

    private static func scanCopilotCLI() -> ToolInfo? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configDir = "\(home)/.config/github-copilot"
        let copilotDir = "\(home)/.copilot"
        guard FileManager.default.fileExists(atPath: configDir)
            || FileManager.default.fileExists(atPath: copilotDir) else { return nil }

        let version = extractVersion(resolveAndRun("copilot", args: ["--version"]))

        let appsPath = "\(configDir)/apps.json"
        let apps = readJSON(appsPath) as? [String: Any]

        var authType: String?
        var details: [String: String] = [:]
        var quota: [String: String] = [:]

        if let a = apps {
            let accountCount = a.keys.count
            details["linked_accounts"] = "\(accountCount)"
            authType = "GitHub OAuth"
            for (_, appInfo) in a {
                if let info = appInfo as? [String: Any],
                   let user = info["user"] as? String {
                    quota["github_user"] = user
                    break
                }
            }
            quota["provider"] = "GitHub"
        }

        // Check versions.json for installed editor plugins
        let versionsPath = "\(configDir)/versions.json"
        if let versions = readJSON(versionsPath) as? [String: String] {
            let editors = versions.map { "\($0.key) v\($0.value)" }
            if !editors.isEmpty {
                details["editor_plugins"] = editors.joined(separator: ", ")
            }
        }

        // Scan skills from ~/.copilot/skills
        let copilotSkillsDir = "\(copilotDir)/skills"
        let copilotSkills = scanSkillsDirectory(copilotSkillsDir)

        return ToolInfo(
            id: "copilot-cli",
            name: "GitHub Copilot",
            version: version,
            icon: "\u{1F916}",
            modelName: nil,
            apiEndpoint: nil,
            authType: authType,
            reasoningLevel: nil,
            subscription: nil,
            plugins: [],
            mcpServers: [],
            skills: copilotSkills.map { $0.name },
            skillDetails: copilotSkills,
            hookIntegrated: false,
            configPath: appsPath,
            quota: quota,
            details: details
        )
    }

    // MARK: - Cursor

    private static func scanCursor() -> ToolInfo? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configDir = "\(home)/.cursor"
        guard FileManager.default.fileExists(atPath: configDir) else { return nil }

        let hooksPath = "\(configDir)/hooks.json"
        let hooks = readJSON(hooksPath) as? [String: Any]

        var plugins: [String] = []
        var details: [String: String] = [:]
        var hookIntegrated = false

        if let h = hooks {
            // Cursor hooks.json has { hooks: { eventName: [{ command: "..." }] } }
            let hooksJSON = String(data: (try? JSONSerialization.data(withJSONObject: h)) ?? Data(), encoding: .utf8) ?? ""
            hookIntegrated = hooksJSON.localizedCaseInsensitiveContains("clawd")
            if let hookMap = h["hooks"] as? [String: Any] {
                plugins = Array(hookMap.keys).sorted()
                details["hook_events"] = "\(hookMap.count)"
            }
        }

        return ToolInfo(
            id: "cursor",
            name: "Cursor",
            version: nil,
            icon: "\u{1F5B1}",
            modelName: nil,
            apiEndpoint: nil,
            authType: nil,
            reasoningLevel: nil,
            subscription: nil,
            plugins: plugins,
            mcpServers: [],
            skills: [],
            skillDetails: [],
            hookIntegrated: hookIntegrated,
            configPath: hooksPath,
            quota: [:],
            details: details
        )
    }

    // MARK: - Kiro

    private static func scanKiro() -> ToolInfo? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configDir = "\(home)/.kiro"
        guard FileManager.default.fileExists(atPath: configDir) else { return nil }

        let argvPath = "\(configDir)/argv.json"
        let argv = readJSON(argvPath) as? [String: Any]

        var details: [String: String] = [:]
        var mcpServers: [String] = []
        var hookIntegrated = false

        // Count agent configs and detect clawd agent
        let agentsDir = "\(configDir)/agents"
        if let agents = try? FileManager.default.contentsOfDirectory(atPath: agentsDir) {
            let agentFiles = agents.filter { $0.hasSuffix(".json") || $0.hasSuffix(".yaml") }
            details["agent_count"] = "\(agentFiles.count)"
            hookIntegrated = agents.contains(where: { $0.lowercased().contains("clawd") })
        }

        // Scan skills with descriptions
        let skillsDir = "\(configDir)/skills"
        let skillDetails = scanSkillsDirectory(skillsDir)
        let skills = skillDetails.map { $0.name }

        // Count powers (extensions)
        let powersDir = "\(configDir)/powers"
        if let powerEntries = try? FileManager.default.contentsOfDirectory(atPath: powersDir) {
            let powers = powerEntries.filter { !$0.hasPrefix(".") }
            if !powers.isEmpty {
                details["powers"] = "\(powers.count)"
            }
        }

        // Check MCP from settings
        let settingsDir = "\(configDir)/settings"
        if let settingsFiles = try? FileManager.default.contentsOfDirectory(atPath: settingsDir) {
            for file in settingsFiles where file.hasSuffix(".json") {
                if let s = readJSON("\(settingsDir)/\(file)") as? [String: Any],
                   let mcp = s["mcpServers"] as? [String: Any] {
                    mcpServers = Array(mcp.keys).sorted()
                }
            }
        }

        if let a = argv {
            for (k, v) in a {
                if let s = v as? String { details[k] = s }
                else if let b = v as? Bool { details[k] = "\(b)" }
            }
        }

        return ToolInfo(
            id: "kiro",
            name: "Kiro",
            version: nil,
            icon: "\u{26A1}",
            modelName: nil,
            apiEndpoint: "https://api.aws.amazon.com",
            authType: "AWS",
            reasoningLevel: nil,
            subscription: nil,
            plugins: [],
            mcpServers: mcpServers,
            skills: skills,
            skillDetails: skillDetails,
            hookIntegrated: hookIntegrated,
            configPath: argvPath,
            quota: ["provider": "AWS"],
            details: details
        )
    }

    // MARK: - Pi

    private static func scanPi() -> ToolInfo? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configDir = "\(home)/.pi/agent"
        guard FileManager.default.fileExists(atPath: configDir) else { return nil }

        let version = extractVersion(resolveAndRun("pi", args: ["--version"]))

        var details: [String: String] = [:]
        var hookIntegrated = false

        // Check clawd extension
        let extDir = "\(configDir)/extensions/clawd"
        hookIntegrated = FileManager.default.fileExists(atPath: "\(extDir)/index.ts")

        // Count extensions
        let extensionsDir = "\(configDir)/extensions"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: extensionsDir) {
            let exts = entries.filter { !$0.hasPrefix(".") }
            details["extensions"] = "\(exts.count)"
        }

        // Scan skills
        let skillsDir = "\(configDir)/skills"
        let skillDetails = scanSkillsDirectory(skillsDir)
        let skills = skillDetails.map { $0.name }

        // Check settings
        let settingsPath = "\(configDir)/settings.json"
        if let settings = readJSON(settingsPath) as? [String: Any] {
            if let model = settings["model"] as? String {
                details["model"] = model
            }
            if let provider = settings["provider"] as? String {
                details["provider"] = provider
            }
        }

        return ToolInfo(
            id: "pi",
            name: "Pi",
            version: version,
            icon: "\u{03C0}",
            modelName: details["model"],
            apiEndpoint: nil,
            authType: details["provider"],
            reasoningLevel: nil,
            subscription: nil,
            plugins: [],
            mcpServers: [],
            skills: skills,
            skillDetails: skillDetails,
            hookIntegrated: hookIntegrated,
            configPath: configDir,
            quota: [:],
            details: details
        )
    }

    // MARK: - Helpers

    private static func parseJWTClaims(_ jwt: String) -> [String: Any] {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var payload = String(parts[1])
        payload = payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    private static func parseJWTQuota(_ jwt: String) -> [String: String] {
        let json = parseJWTClaims(jwt)

        var quota: [String: String] = [:]
        if let auth = json["https://api.openai.com/auth"] as? [String: Any] {
            if let plan = auth["chatgpt_plan_type"] as? String {
                quota["plan"] = plan
            }
            if let until = auth["chatgpt_subscription_active_until"] as? String {
                // Shorten ISO date to just date part
                let datePart = String(until.prefix(10))
                quota["subscription_until"] = datePart
            }
        }
        return quota
    }

    /// Scan a skills directory, reading SKILL.md frontmatter for name and description
    private static func scanSkillsDirectory(_ path: String) -> [SkillInfo] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        var results: [SkillInfo] = []
        for entry in entries.sorted() where !entry.hasPrefix(".") {
            let skillMD = "\(path)/\(entry)/SKILL.md"
            guard let content = try? String(contentsOfFile: skillMD, encoding: .utf8) else {
                results.append(SkillInfo(name: entry, description: ""))
                continue
            }
            // Parse YAML frontmatter between --- markers
            let lines = content.components(separatedBy: "\n")
            var inFrontmatter = false
            var name: String?
            var desc: String = ""
            var readingDesc = false
            for line in lines {
                if line.trimmingCharacters(in: .whitespaces) == "---" {
                    if inFrontmatter { break }
                    inFrontmatter = true
                    continue
                }
                guard inFrontmatter else { continue }
                if line.hasPrefix("name:") {
                    name = line.replacingOccurrences(of: "name:", with: "").trimmingCharacters(in: .whitespaces)
                    readingDesc = false
                } else if line.hasPrefix("description:") {
                    let inline = line.replacingOccurrences(of: "description:", with: "").trimmingCharacters(in: .whitespaces)
                    if inline == "|" || inline == ">" {
                        readingDesc = true
                    } else {
                        desc = inline
                    }
                } else if readingDesc && (line.hasPrefix("  ") || line.hasPrefix("\t")) {
                    if !desc.isEmpty { desc += " " }
                    desc += line.trimmingCharacters(in: .whitespaces)
                } else {
                    readingDesc = false
                }
            }
            // Truncate long descriptions
            if desc.count > 120 {
                desc = String(desc.prefix(117)) + "..."
            }
            results.append(SkillInfo(name: name ?? entry, description: desc))
        }
        return results
    }

    private static func resolveAndRun(_ name: String, extraPaths: [String] = [], args: [String] = []) -> String? {
        let searchPaths = extraPaths + [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin",
        ]

        for dir in searchPaths {
            let fullPath = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return runCommand(fullPath, args: args, timeout: 3)
            }
        }

        // Fallback: use which
        if let whichResult = runCommand("/usr/bin/which", args: [name], timeout: 3),
           !whichResult.isEmpty {
            return runCommand(whichResult, args: args, timeout: 3)
        }

        return nil
    }

    private static func runCommand(_ command: String, args: [String] = [], timeout: TimeInterval = 3) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                process.waitUntilExit()
                group.leave()
            }
            let result = group.wait(timeout: .now() + timeout)
            if result == .timedOut {
                process.terminate()
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            // Take only the first line to avoid multi-line output (e.g. update prompts)
            let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.components(separatedBy: .newlines).first ?? raw
        } catch {
            return nil
        }
    }

    /// Extract a bare version number from CLI output like "codex-cli 0.116.0" or "GitHub Copilot CLI 1.0.31"
    private static func extractVersion(_ raw: String?) -> String? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        // Match version-like pattern: digits.digits[.digits...]
        let pattern = #"(\d+\.\d+(?:\.\d+)*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let range = Range(match.range(at: 1), in: raw) else {
            // No version pattern found — likely an error message, discard
            return nil
        }
        return String(raw[range])
    }

    private static func readJSON(_ path: String) -> Any? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func extractTOMLValue(_ content: String, key: String) -> String? {
        // Simple regex: key = "value" or key = 'value'
        let pattern = #"(?m)^\s*"# + NSRegularExpression.escapedPattern(for: key) + #"\s*=\s*[\"']([^\"']*)[\"']"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let range = Range(match.range(at: 1), in: content) else {
            return nil
        }
        return String(content[range])
    }
}
