import Foundation
import os

private let hookLogger = Logger(subsystem: "com.clawd.ClawdOnMac", category: "Hooks")

/// Manages hook registration into AI tool settings files.
/// Supports Claude Code, CodeBuddy, Copilot CLI, Cursor, Gemini, Kiro, and opencode.
class HookRegistrar {

    // MARK: - Constants

    static let MARKER = "clawd-hook.js"

    /// All hook events for Claude Code.
    static let CORE_HOOKS = [
        "SessionStart", "SessionEnd", "UserPromptSubmit",
        "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "Stop", "SubagentStart", "SubagentStop",
        "Notification", "Elicitation", "WorktreeCreate"
    ]

    /// Versioned hooks requiring minimum CC version.
    static let VERSIONED_HOOKS: [(event: String, minVersion: String)] = [
        ("PreCompact", "2.1.76"),
        ("PostCompact", "2.1.76"),
        ("StopFailure", "2.1.78")
    ]

    // Tool-specific hook events
    static let CODEBUDDY_HOOKS = [
        "SessionStart", "SessionEnd", "UserPromptSubmit",
        "PreToolUse", "PostToolUse", "Stop",
        "Notification", "PreCompact"
    ]

    static let CURSOR_HOOKS = [
        "sessionStart", "sessionEnd", "beforeSubmitPrompt",
        "preToolUse", "postToolUse", "postToolUseFailure",
        "subagentStart", "subagentStop", "preCompact",
        "afterAgentThought", "stop"
    ]

    static let GEMINI_HOOKS = [
        "SessionStart", "SessionEnd", "BeforeAgent",
        "AfterAgent", "BeforeTool", "AfterTool",
        "Notification", "PreCompress"
    ]

    static let COPILOT_HOOKS = [
        "sessionStart", "sessionEnd", "userPromptSubmitted",
        "preToolUse", "postToolUse", "errorOccurred",
        "agentStop", "subagentStart", "subagentStop",
        "preCompact"
    ]

    static let KIRO_HOOKS = [
        "agentSpawn", "userPromptSubmit",
        "preToolUse", "postToolUse", "stop"
    ]

    private var lastSyncTime: Date = .distantPast
    private let SYNC_RATE_LIMIT: TimeInterval = 5.0

    // MARK: - Claude Code hooks

    /// Register Clawd hooks into ~/.claude/settings.json.
    @discardableResult
    func registerClaudeHooks(port: Int, silent: Bool = true) -> (added: Int, skipped: Int) {
        let settingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json").path

        var settings = readJSON(at: settingsPath) ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        let hookScript = hookScriptPath()
        let nodeBin = resolveNodeBin()

        var added = 0
        var skipped = 0

        for event in Self.CORE_HOOKS {
            var eventHooks = hooks[event] as? [[String: Any]] ?? []

            if eventHooks.contains(where: { isClawdHook($0) }) {
                skipped += 1
                continue
            }

            guard let command = buildHookCommand(nodeBin: nodeBin, hookScript: hookScript, event: event) else { skipped += 1; continue }
            let hook: [String: Any] = [
                "matcher": "",
                "hooks": [["type": "command", "command": command]]
            ]
            eventHooks.append(hook)
            hooks[event] = eventHooks
            added += 1
        }

        // HTTP hooks for PermissionRequest
        var permHooks = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        if !permHooks.contains(where: { isClawdHook($0) }) {
            let hook: [String: Any] = [
                "matcher": "",
                "hooks": [["type": "http", "url": "http://localhost:\(port)/permission", "timeout": 600]]
            ]
            permHooks.append(hook)
            hooks["PermissionRequest"] = permHooks
            added += 1
        }

        settings["hooks"] = hooks

        if added > 0 {
            writeJSON(settings, to: settingsPath)
            if !silent {
                hookLogger.info("Registered \(added, privacy: .public) Claude Code hooks")
            }
        }

        return (added: added, skipped: skipped)
    }

    /// Remove all Clawd hooks from ~/.claude/settings.json.
    func unregisterClaudeHooks() {
        let settingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json").path
        removeClawdHooksFromJSON(at: settingsPath, hooksKey: "hooks")
    }

    /// Unified unregister: remove clawd hooks for a specific agent.
    func unregisterHooks(agentId: String, port: Int) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        switch agentId {
        case "claude-code":
            unregisterClaudeHooks()

        case "codebuddy":
            removeClawdHooksFromJSON(at: "\(home)/.codebuddy/settings.json", hooksKey: "hooks", marker: "codebuddy-hook.js")

        case "copilot-cli":
            removeClawdHooksFromJSON(at: "\(home)/.copilot/hooks/hooks.json", hooksKey: "hooks", marker: "copilot-hook.js")

        case "cursor-agent":
            removeClawdHooksFromJSON(at: "\(home)/.cursor/hooks.json", hooksKey: "hooks", marker: "cursor-hook.js")

        case "gemini-cli":
            removeClawdHooksFromJSON(at: "\(home)/.gemini/settings.json", hooksKey: "hooks", marker: "gemini-hook.js")

        case "kiro-cli":
            let agentFile = "\(home)/.kiro/agents/clawd.json"
            try? FileManager.default.removeItem(atPath: agentFile)

        case "opencode":
            let configPath = "\(home)/.config/opencode/opencode.json"
            guard var config = readJSON(at: configPath),
                  var plugins = config["plugin"] as? [String] else { return }
            plugins.removeAll { $0.contains("clawd") || $0.contains("opencode-plugin") }
            config["plugin"] = plugins.isEmpty ? nil : plugins
            writeJSON(config, to: configPath)

        case "pi":
            let extDir = "\(home)/.pi/agent/extensions/clawd"
            try? FileManager.default.removeItem(atPath: extDir)

        default:
            break
        }
    }

    /// Re-register hooks for a specific agent.
    func registerHooks(agentId: String, port: Int) {
        switch agentId {
        case "claude-code":   registerClaudeHooks(port: port)
        case "codebuddy":     registerCodeBuddyHooks(port: port)
        case "copilot-cli":   registerCopilotHooks()
        case "cursor-agent":  registerCursorHooks()
        case "gemini-cli":    registerGeminiHooks()
        case "kiro-cli":      registerKiroHooks()
        case "opencode":      registerOpencodePlugin()
        case "pi":            registerPiExtension()
        default: break
        }
    }

    /// Helper: remove clawd hooks from a JSON settings file.
    private func removeClawdHooksFromJSON(at path: String, hooksKey: String, marker: String = MARKER) {
        guard var settings = readJSON(at: path) else { return }
        guard var hooks = settings[hooksKey] as? [String: Any] else { return }

        var changed = false
        for (event, value) in hooks {
            guard var arr = value as? [[String: Any]] else { continue }
            let before = arr.count
            arr.removeAll { isClawdHook($0, marker: marker) }
            if arr.count != before {
                hooks[event] = arr.isEmpty ? nil : arr
                changed = true
            }
        }

        if changed {
            settings[hooksKey] = hooks
            writeJSON(settings, to: path)
        }
    }

    /// Check if hooks are registered (for wipe detection).
    func areClaudeHooksRegistered() -> Bool {
        let settingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json").path

        guard let settings = readJSON(at: settingsPath),
              let hooks = settings["hooks"] as? [String: Any] else { return false }

        for event in Self.CORE_HOOKS {
            if let arr = hooks[event] as? [[String: Any]] {
                if arr.contains(where: { isClawdHook($0) }) {
                    return true
                }
            }
        }
        return false
    }

    /// Check if a specific agent has clawd hooks actually installed.
    func isHookInstalled(agentId: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default

        switch agentId {
        case "claude-code":
            return areClaudeHooksRegistered()

        case "codebuddy":
            let path = "\(home)/.codebuddy/settings.json"
            guard let settings = readJSON(at: path),
                  let hooks = settings["hooks"] as? [String: Any] else { return false }
            let json = String(data: (try? JSONSerialization.data(withJSONObject: hooks)) ?? Data(), encoding: .utf8) ?? ""
            return json.localizedCaseInsensitiveContains("clawd") || json.contains("codebuddy-hook.js")

        case "cursor-agent":
            let path = "\(home)/.cursor/hooks.json"
            guard let settings = readJSON(at: path),
                  let hooks = settings["hooks"] as? [String: Any] else { return false }
            let json = String(data: (try? JSONSerialization.data(withJSONObject: hooks)) ?? Data(), encoding: .utf8) ?? ""
            return json.localizedCaseInsensitiveContains("clawd") || json.contains("cursor-hook.js")

        case "gemini-cli":
            let path = "\(home)/.gemini/settings.json"
            guard let settings = readJSON(at: path),
                  let hooks = settings["hooks"] as? [String: Any] else { return false }
            let json = String(data: (try? JSONSerialization.data(withJSONObject: hooks)) ?? Data(), encoding: .utf8) ?? ""
            return json.localizedCaseInsensitiveContains("clawd") || json.contains("gemini-hook.js")

        case "kiro-cli":
            let agentsDir = "\(home)/.kiro/agents"
            guard fm.fileExists(atPath: agentsDir),
                  let files = try? fm.contentsOfDirectory(atPath: agentsDir) else { return false }
            return files.contains(where: { $0.lowercased().contains("clawd") })

        case "opencode":
            let configPath = "\(home)/.config/opencode/config.json"
            guard let config = readJSON(at: configPath),
                  let plugins = config["plugin"] as? [String] else { return false }
            return plugins.contains(where: { $0.contains("clawd") || $0.contains("opencode-plugin") })

        case "pi":
            let extDir = "\(home)/.pi/agent/extensions/clawd"
            return fm.fileExists(atPath: "\(extDir)/index.ts")

        case "copilot-cli":
            let path = "\(home)/.copilot/hooks/hooks.json"
            guard let settings = readJSON(at: path),
                  let hooks = settings["hooks"] as? [String: Any] else { return false }
            let json = String(data: (try? JSONSerialization.data(withJSONObject: hooks)) ?? Data(), encoding: .utf8) ?? ""
            return json.localizedCaseInsensitiveContains("clawd") || json.contains("copilot-hook.js")

        case "codex":
            return false

        default:
            return false
        }
    }

    // MARK: - Register all tools

    /// Register hooks for all supported tools. Skips tools not installed.
    @discardableResult
    func registerAllHooks(port: Int) -> (total: Int, skipped: Int) {
        let now = Date()
        guard now.timeIntervalSince(lastSyncTime) >= SYNC_RATE_LIMIT else {
            return (total: 0, skipped: 0)
        }
        lastSyncTime = now

        var total = 0
        var skipped = 0

        let cc = registerClaudeHooks(port: port)
        total += cc.added; skipped += cc.skipped

        let cb = registerCodeBuddyHooks(port: port)
        total += cb.added; skipped += cb.skipped

        let cu = registerCursorHooks()
        total += cu.added; skipped += cu.skipped

        let co = registerCopilotHooks()
        total += co.added; skipped += co.skipped

        let ge = registerGeminiHooks()
        total += ge.added; skipped += ge.skipped

        let ki = registerKiroHooks()
        total += ki.added; skipped += ki.skipped

        let oc = registerOpencodePlugin()
        total += oc.added ? 1 : 0

        let pi = registerPiExtension()
        total += pi.added ? 1 : 0

        hookLogger.info("Hook sync: \(total) added, \(skipped) skipped")
        return (total: total, skipped: skipped)
    }

    // MARK: - CodeBuddy hooks (~/.codebuddy/settings.json)

    @discardableResult
    func registerCodeBuddyHooks(port: Int) -> (added: Int, skipped: Int) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/.codebuddy"
        guard FileManager.default.fileExists(atPath: dir) else { return (0, 0) }

        let settingsPath = "\(dir)/settings.json"
        var settings = readJSON(at: settingsPath) ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        let hookScript = hookScriptPath(tool: "codebuddy")
        let nodeBin = resolveNodeBin()

        var added = 0
        var skipped = 0

        for event in Self.CODEBUDDY_HOOKS {
            var eventHooks = hooks[event] as? [[String: Any]] ?? []
            if eventHooks.contains(where: { isClawdHook($0, marker: "codebuddy-hook.js") }) {
                skipped += 1
                continue
            }

            guard let command = buildHookCommand(nodeBin: nodeBin, hookScript: hookScript, event: event) else { skipped += 1; continue }
            eventHooks.append(["type": "command", "command": command])
            hooks[event] = eventHooks
            added += 1
        }

        // HTTP hook for PermissionRequest
        var permHooks = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        if !permHooks.contains(where: { isClawdHook($0) }) {
            permHooks.append(["type": "url", "url": "http://localhost:\(port)/permission"])
            hooks["PermissionRequest"] = permHooks
            added += 1
        }

        if added > 0 {
            settings["hooks"] = hooks
            writeJSON(settings, to: settingsPath)
        }
        return (added: added, skipped: skipped)
    }

    // MARK: - Cursor hooks (~/.cursor/hooks.json)

    @discardableResult
    func registerCursorHooks() -> (added: Int, skipped: Int) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/.cursor"
        guard FileManager.default.fileExists(atPath: dir) else { return (0, 0) }

        let hooksPath = "\(dir)/hooks.json"
        var settings = readJSON(at: hooksPath) ?? [:]

        let hookScript = hookScriptPath(tool: "cursor")
        let nodeBin = resolveNodeBin()

        // Cursor hooks.json uses nested format: { "version": 1, "hooks": { "event": [...] } }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        var added = 0
        var skipped = 0

        for event in Self.CURSOR_HOOKS {
            var eventHooks = hooks[event] as? [[String: Any]] ?? []
            if eventHooks.contains(where: { isClawdHook($0, marker: "cursor-hook.js") }) {
                skipped += 1
                continue
            }

            guard let command = buildHookCommand(nodeBin: nodeBin, hookScript: hookScript, event: event) else { skipped += 1; continue }
            eventHooks.append(["type": "command", "command": command])
            hooks[event] = eventHooks
            added += 1
        }

        if added > 0 {
            settings["hooks"] = hooks
            if settings["version"] == nil {
                settings["version"] = 1
            }
            writeJSON(settings, to: hooksPath)
        }
        return (added: added, skipped: skipped)
    }

    // MARK: - Copilot CLI hooks (~/.copilot/hooks/hooks.json)

    @discardableResult
    func registerCopilotHooks() -> (added: Int, skipped: Int) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/.copilot"
        guard FileManager.default.fileExists(atPath: dir) else { return (0, 0) }

        let hooksDir = "\(dir)/hooks"
        try? FileManager.default.createDirectory(atPath: hooksDir, withIntermediateDirectories: true)

        let hooksPath = "\(hooksDir)/hooks.json"
        var settings = readJSON(at: hooksPath) ?? [:]

        let hookScript = hookScriptPath(tool: "copilot")
        let nodeBin = resolveNodeBin()

        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        var added = 0
        var skipped = 0

        for event in Self.COPILOT_HOOKS {
            var eventHooks = hooks[event] as? [[String: Any]] ?? []
            if eventHooks.contains(where: { isClawdHook($0, marker: "copilot-hook.js") }) {
                skipped += 1
                continue
            }

            guard let command = buildHookCommand(nodeBin: nodeBin, hookScript: hookScript, event: event) else { skipped += 1; continue }
            eventHooks.append(["type": "command", "bash": command, "powershell": command, "timeoutSec": 5])
            hooks[event] = eventHooks
            added += 1
        }

        if added > 0 {
            settings["hooks"] = hooks
            if settings["version"] == nil {
                settings["version"] = 1
            }
            writeJSON(settings, to: hooksPath)
        }
        return (added: added, skipped: skipped)
    }

    // MARK: - Gemini hooks (~/.gemini/settings.json)

    @discardableResult
    func registerGeminiHooks() -> (added: Int, skipped: Int) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/.gemini"
        guard FileManager.default.fileExists(atPath: dir) else { return (0, 0) }

        let settingsPath = "\(dir)/settings.json"
        var settings = readJSON(at: settingsPath) ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        let hookScript = hookScriptPath(tool: "gemini")
        let nodeBin = resolveNodeBin()

        var added = 0
        var skipped = 0

        for event in Self.GEMINI_HOOKS {
            var eventHooks = hooks[event] as? [[String: Any]] ?? []
            if eventHooks.contains(where: { isClawdHook($0, marker: "gemini-hook.js") }) {
                skipped += 1
                continue
            }

            guard let command = buildHookCommand(nodeBin: nodeBin, hookScript: hookScript, event: event) else { skipped += 1; continue }
            eventHooks.append(["type": "command", "command": command])
            hooks[event] = eventHooks
            added += 1
        }

        if added > 0 {
            settings["hooks"] = hooks
            writeJSON(settings, to: settingsPath)
        }
        return (added: added, skipped: skipped)
    }

    // MARK: - Kiro hooks (~/.kiro/agents/clawd.json)

    @discardableResult
    func registerKiroHooks() -> (added: Int, skipped: Int) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/.kiro"
        guard FileManager.default.fileExists(atPath: dir) else { return (0, 0) }

        let agentsDir = "\(dir)/agents"
        try? FileManager.default.createDirectory(atPath: agentsDir, withIntermediateDirectories: true)

        let configPath = "\(agentsDir)/clawd.json"
        var config = readJSON(at: configPath) ?? [:]

        let hookScript = hookScriptPath(tool: "kiro")
        let nodeBin = resolveNodeBin()

        if config["name"] == nil {
            config["name"] = "clawd"
            config["description"] = "Clawd desktop pet hook integration"
        }

        var hooks = config["hooks"] as? [String: Any] ?? [:]
        var added = 0
        var skipped = 0

        for event in Self.KIRO_HOOKS {
            var eventHooks = hooks[event] as? [[String: Any]] ?? []
            if eventHooks.contains(where: { isClawdHook($0, marker: "kiro-hook.js") }) {
                skipped += 1
                continue
            }

            guard let command = buildHookCommand(nodeBin: nodeBin, hookScript: hookScript, event: event) else { skipped += 1; continue }
            eventHooks.append(["type": "command", "command": command])
            hooks[event] = eventHooks
            added += 1
        }

        if added > 0 {
            config["hooks"] = hooks
            writeJSON(config, to: configPath)
        }
        return (added: added, skipped: skipped)
    }

    // MARK: - opencode plugin (~/.config/opencode/opencode.json)

    @discardableResult
    func registerOpencodePlugin() -> (added: Bool, skipped: Bool) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configDir = "\(home)/.config/opencode"
        guard FileManager.default.fileExists(atPath: configDir) else {
            return (added: false, skipped: true)
        }

        let configPath = "\(configDir)/opencode.json"
        var config = readJSON(at: configPath) ?? [:]

        let pluginDir = resolveOpencodePluginDir()

        var plugins = config["plugin"] as? [String] ?? []
        if plugins.contains(where: { $0.contains("clawd") || $0.contains("opencode-plugin") }) {
            return (added: false, skipped: false)
        }

        plugins.append(pluginDir)
        config["plugin"] = plugins
        writeJSON(config, to: configPath)
        return (added: true, skipped: false)
    }

    private func resolveOpencodePluginDir() -> String {
        if let resourcePath = Bundle.main.resourcePath {
            let path = resourcePath + "/hooks/opencode-plugin"
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.clawd/hooks/opencode-plugin"
    }

    // MARK: - Pi extension (~/.pi/agent/extensions/clawd/)

    @discardableResult
    func registerPiExtension() -> (added: Bool, skipped: Bool) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let piDir = "\(home)/.pi/agent"
        guard FileManager.default.fileExists(atPath: piDir) else {
            return (added: false, skipped: true)
        }

        let extDir = "\(piDir)/extensions/clawd"
        let destFile = "\(extDir)/index.ts"

        // Already installed
        if FileManager.default.fileExists(atPath: destFile) {
            return (added: false, skipped: false)
        }

        do {
            try FileManager.default.createDirectory(atPath: extDir, withIntermediateDirectories: true)
            try piExtensionContent().write(toFile: destFile, atomically: true, encoding: .utf8)
            hookLogger.info("Pi extension installed at \(extDir)")
            return (added: true, skipped: false)
        } catch {
            hookLogger.error("Failed to install Pi extension: \(error.localizedDescription)")
            return (added: false, skipped: true)
        }
    }

    private func piExtensionContent() -> String {
        """
        // Clawd — Pi Extension (auto-generated, do not edit)
        // Forwards session/tool events to Clawd HTTP server.
        import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
        import { readFileSync } from "fs";
        import { homedir } from "os";
        import { join } from "path";

        const CLAWD_DIR = join(homedir(), ".clawd");
        const RUNTIME_PATH = join(CLAWD_DIR, "runtime.json");
        const PORTS = [23333, 23334, 23335, 23336, 23337];
        const AGENT_ID = "pi";

        let port: number | null = null;
        let lastState = "";
        let sessionId = `pi-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;

        function getPort(): number {
          if (!port) {
            try {
              const c = JSON.parse(readFileSync(RUNTIME_PATH, "utf-8"));
              if (c.port) port = c.port;
            } catch {}
            if (!port) port = PORTS[0];
          }
          return port;
        }

        async function postState(state: string, event?: string) {
          if (state === lastState) return;
          lastState = state;
          try {
            const ac = new AbortController();
            const t = setTimeout(() => ac.abort(), 1000);
            await fetch(`http://127.0.0.1:${getPort()}/state`, {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ state, event: event || state, session_id: sessionId, agent_id: AGENT_ID }),
              signal: ac.signal,
            });
            clearTimeout(t);
          } catch { port = null; }
        }

        async function requestPermission(toolName: string, toolInput: Record<string, unknown>) {
          try {
            const ac = new AbortController();
            const t = setTimeout(() => ac.abort(), 30000);
            const res = await fetch(`http://127.0.0.1:${getPort()}/permission`, {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ tool_name: toolName, tool_input: toolInput, session_id: sessionId, agent_id: AGENT_ID }),
              signal: ac.signal,
            });
            clearTimeout(t);
            if (res.ok) return await res.json() as { behavior: string };
          } catch { port = null; }
          return null;
        }

        export default function (pi: ExtensionAPI) {
          pi.on("session_start", async () => {
            sessionId = `pi-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
            await postState("idle", "session_start");
          });
          pi.on("session_shutdown", async () => { await postState("session_end", "session_shutdown"); });
          pi.on("input", async () => { await postState("thinking", "input"); });
          pi.on("agent_start", async () => { await postState("thinking", "agent_start"); });
          pi.on("agent_end", async () => { await postState("attention", "agent_end"); });
          pi.on("tool_call", async (event) => {
            await postState("working", "tool_call");
            const safe = new Set(["read", "search"]);
            if (safe.has(event.toolName)) return;
            const r = await requestPermission(event.toolName, event.input || {});
            if (r && r.behavior === "deny") return { block: true, reason: "Blocked by Clawd" };
          });
          pi.on("tool_result", async () => { await postState("working", "tool_result"); });
          pi.on("session_before_compact", async () => { await postState("sweeping", "compact"); });
          pi.on("session_compact", async () => { await postState("attention", "compact_done"); });
        }
        """
    }

    // MARK: - Hook script path

    private func hookScriptPath(tool: String = "clawd") -> String {
        let scriptName: String
        switch tool {
        case "codebuddy": scriptName = "codebuddy-hook.js"
        case "copilot": scriptName = "copilot-hook.js"
        case "cursor": scriptName = "cursor-hook.js"
        case "gemini": scriptName = "gemini-hook.js"
        case "kiro": scriptName = "kiro-hook.js"
        default: scriptName = "clawd-hook.js"
        }

        if let resourcePath = Bundle.main.resourcePath {
            let path = resourcePath + "/hooks/\(scriptName)"
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.clawd/hooks/\(scriptName)",
            "/Applications/Clawd.app/Contents/Resources/app/hooks/\(scriptName)"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? scriptName
    }

    // MARK: - Node binary resolution

    private func resolveNodeBin() -> String {
        let candidates = [
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/bin/node"
        ]

        // Also check common version managers
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let vmCandidates = [
            "\(home)/.nvm/versions/node",
            "\(home)/.volta/bin/node",
            "\(home)/.fnm/node-versions"
        ]

        for c in candidates {
            if FileManager.default.fileExists(atPath: c) { return c }
        }

        // nvm: find latest version
        let nvmPath = vmCandidates[0]
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmPath) {
            let sorted = versions.sorted().reversed()
            for v in sorted {
                let nodePath = "\(nvmPath)/\(v)/bin/node"
                if FileManager.default.fileExists(atPath: nodePath) {
                    return nodePath
                }
            }
        }

        // volta
        if FileManager.default.fileExists(atPath: vmCandidates[1]) {
            return vmCandidates[1]
        }

        return "node"
    }

    // MARK: - JSON helpers

    private func isClawdHook(_ hook: [String: Any], marker: String = MARKER) -> Bool {
        if let cmd = hook["command"] as? String, cmd.contains(marker) { return true }
        if let bash = hook["bash"] as? String, bash.contains(marker) { return true }
        if let url = hook["url"] as? String, url.contains("localhost") && url.contains("/permission") { return true }
        // Check nested hooks arrays (Claude Code format)
        if let nestedHooks = hook["hooks"] as? [[String: Any]] {
            for h in nestedHooks {
                if let cmd = h["command"] as? String, cmd.contains(marker) { return true }
                if let url = h["url"] as? String, url.contains("localhost") && url.contains("/permission") { return true }
            }
        }
        return false
    }

    private func readJSON(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private func writeJSON(_ obj: [String: Any], to path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }

        // Atomic write — Data.write with .atomic handles temp file + rename internally
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            hookLogger.error("writeJSON failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Validate a path component does not contain shell metacharacters.
    private func shellSafePath(_ path: String) -> Bool {
        let forbidden: Set<Character> = ["`", "$", "!", ";", "&", "|", "(", ")", "{", "}", "<", ">", "\"", "\\", "\n", "\r"]
        return !path.contains(where: { forbidden.contains($0) })
    }

    /// Build a shell command string with validated paths.
    func buildHookCommand(nodeBin: String, hookScript: String, event: String) -> String? {
        guard shellSafePath(nodeBin), shellSafePath(hookScript) else {
            hookLogger.error("Rejected unsafe path in hook command")
            return nil
        }
        return "\"\(nodeBin)\" \"\(hookScript)\" \"\(event)\""
    }
}
