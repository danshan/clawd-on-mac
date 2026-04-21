import Foundation
import os

// MARK: - Schema

private let logger = Logger(subsystem: "com.clawd.onmac", category: "Preferences")

struct PreferencesSnapshot: Codable, Equatable {
    var version: Int = PreferencesSnapshot.currentVersion
    // Window state
    var x: Double = 0
    var y: Double = 0
    var positionSaved: Bool = false
    var size: String = "P:10"
    // Mini mode
    var miniMode: Bool = false
    var miniEdge: String = "right"
    var preMiniX: Double = 0
    var preMiniY: Double = 0
    // State resume
    var lastDisplayState: String = "idle"
    var sleepMode: String = "full"
    // User prefs
    var lang: String = "en"
    var showTray: Bool = true
    var showDock: Bool = false
    var manageClaudeHooksAutomatically: Bool = true
    var autoStartWithClaude: Bool = false
    var openAtLogin: Bool = false
    var openAtLoginHydrated: Bool = false
    var bubbleFollowPet: Bool = false
    var hideBubbles: Bool = false
    var showSessionId: Bool = false
    var soundMuted: Bool = false
    // Theme
    var theme: String = "clawd"
    var themeOverrides: [String: AnyCodable] = [:]
    var themeVariant: [String: String] = [:]
    // Agents
    var agents: [String: AgentConfig] = [:]

    static let currentVersion = 1
    static let validLangs = ["en", "zh", "ko"]
    static let validEdges = ["left", "right"]
    static let validSleepModes = ["full", "direct"]

    // Custom decoder: tolerates missing keys by falling back to defaults.
    init(from decoder: Decoder) throws {
        let d = PreferencesSnapshot()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? d.version
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? d.x
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? d.y
        positionSaved = try c.decodeIfPresent(Bool.self, forKey: .positionSaved) ?? d.positionSaved
        size = try c.decodeIfPresent(String.self, forKey: .size) ?? d.size
        miniMode = try c.decodeIfPresent(Bool.self, forKey: .miniMode) ?? d.miniMode
        miniEdge = try c.decodeIfPresent(String.self, forKey: .miniEdge) ?? d.miniEdge
        preMiniX = try c.decodeIfPresent(Double.self, forKey: .preMiniX) ?? d.preMiniX
        preMiniY = try c.decodeIfPresent(Double.self, forKey: .preMiniY) ?? d.preMiniY
        lastDisplayState = try c.decodeIfPresent(String.self, forKey: .lastDisplayState) ?? d.lastDisplayState
        sleepMode = try c.decodeIfPresent(String.self, forKey: .sleepMode) ?? d.sleepMode
        lang = try c.decodeIfPresent(String.self, forKey: .lang) ?? d.lang
        showTray = try c.decodeIfPresent(Bool.self, forKey: .showTray) ?? d.showTray
        showDock = try c.decodeIfPresent(Bool.self, forKey: .showDock) ?? d.showDock
        manageClaudeHooksAutomatically = try c.decodeIfPresent(Bool.self, forKey: .manageClaudeHooksAutomatically) ?? d.manageClaudeHooksAutomatically
        autoStartWithClaude = try c.decodeIfPresent(Bool.self, forKey: .autoStartWithClaude) ?? d.autoStartWithClaude
        openAtLogin = try c.decodeIfPresent(Bool.self, forKey: .openAtLogin) ?? d.openAtLogin
        openAtLoginHydrated = try c.decodeIfPresent(Bool.self, forKey: .openAtLoginHydrated) ?? d.openAtLoginHydrated
        bubbleFollowPet = try c.decodeIfPresent(Bool.self, forKey: .bubbleFollowPet) ?? d.bubbleFollowPet
        hideBubbles = try c.decodeIfPresent(Bool.self, forKey: .hideBubbles) ?? d.hideBubbles
        showSessionId = try c.decodeIfPresent(Bool.self, forKey: .showSessionId) ?? d.showSessionId
        soundMuted = try c.decodeIfPresent(Bool.self, forKey: .soundMuted) ?? d.soundMuted
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? d.theme
        themeOverrides = try c.decodeIfPresent([String: AnyCodable].self, forKey: .themeOverrides) ?? d.themeOverrides
        themeVariant = try c.decodeIfPresent([String: String].self, forKey: .themeVariant) ?? d.themeVariant
        agents = try c.decodeIfPresent([String: AgentConfig].self, forKey: .agents) ?? d.agents
    }

    init() {}
}

struct AgentConfig: Codable, Equatable {
    var enabled: Bool = true
    var permissionsEnabled: Bool = true

    static let knownAgents = [
        "claude-code", "codex", "copilot-cli", "cursor-agent",
        "gemini-cli", "codebuddy", "kiro-cli", "opencode"
    ]

    static func defaults() -> [String: AgentConfig] {
        var map: [String: AgentConfig] = [:]
        for id in knownAgents {
            map[id] = AgentConfig()
        }
        return map
    }
}

// MARK: - AnyCodable (lightweight wrapper for JSON values)

struct AnyCodable: Codable, Equatable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let b = try? container.decode(Bool.self) {
            value = b
        } else if let i = try? container.decode(Int.self) {
            value = i
        } else if let d = try? container.decode(Double.self) {
            value = d
        } else if let s = try? container.decode(String.self) {
            value = s
        } else if let arr = try? container.decode([AnyCodable].self) {
            value = arr.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let b as Bool:
            try container.encode(b)
        case let i as Int:
            try container.encode(i)
        case let d as Double:
            try container.encode(d)
        case let s as String:
            try container.encode(s)
        case let arr as [Any]:
            try container.encode(arr.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }
}

// MARK: - Validation

extension PreferencesSnapshot {
    /// Coerce a decoded snapshot into a valid state.
    mutating func validate() {
        version = Self.currentVersion
        if !Self.validLangs.contains(lang) { lang = "en" }
        if !Self.validEdges.contains(miniEdge) { miniEdge = "right" }
        if !Self.validSleepModes.contains(sleepMode) { sleepMode = "full" }
        if !isValidSize(size) { size = "P:10" }
        if !x.isFinite { x = 0 }
        if !y.isFinite { y = 0 }
        if !preMiniX.isFinite { preMiniX = 0 }
        if !preMiniY.isFinite { preMiniY = 0 }
        normalizeAgents()
    }

    private func isValidSize(_ s: String) -> Bool {
        if s == "S" || s == "M" || s == "L" { return true }
        let pattern = #"^P:\d+(?:\.\d+)?$"#
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    private mutating func normalizeAgents() {
        // Only keep agent configs the user explicitly set.
        // Missing agents will get their default from hook status at menu build time.
    }
}

// MARK: - Load / Save / Migrate

enum Preferences {
    struct LoadResult {
        let snapshot: PreferencesSnapshot
        let locked: Bool
    }

    static func prefsPath() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".clawd/clawd-prefs.json")
    }

    static func load(from path: URL? = nil) -> LoadResult {
        let url = path ?? prefsPath()
        guard let data = try? Data(contentsOf: url) else {
            return LoadResult(snapshot: PreferencesSnapshot(), locked: false)
        }

        let decoder = JSONDecoder()
        var raw: PreferencesSnapshot
        do {
            raw = try decoder.decode(PreferencesSnapshot.self, from: data)
        } catch {
            logger.error("Failed to decode \(url.path, privacy: .public): \(error, privacy: .public)")
            backup(url)
            return LoadResult(snapshot: PreferencesSnapshot(), locked: false)
        }

        // Future-version guard
        if raw.version > PreferencesSnapshot.currentVersion {
            logger.info("Future version \(raw.version, privacy: .public) > \(PreferencesSnapshot.currentVersion, privacy: .public), read-only mode")
            raw.validate()
            return LoadResult(snapshot: raw, locked: true)
        }

        raw = migrate(raw)
        raw.validate()
        return LoadResult(snapshot: raw, locked: false)
    }

    static func save(_ snapshot: PreferencesSnapshot, to path: URL? = nil) throws {
        let url = path ?? prefsPath()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    static func migrate(_ raw: PreferencesSnapshot) -> PreferencesSnapshot {
        var out = raw
        // v0 → v1: ensure agents + themeOverrides exist (handled by Codable defaults)
        if out.version < 1 {
            out.version = 1
        }
        // Backfill positionSaved
        if !out.positionSaved && (out.x != 0 || out.y != 0) {
            out.positionSaved = true
        }
        return out
    }

    private static func backup(_ url: URL) {
        let backupURL = url.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.copyItem(at: url, to: backupURL)
        logger.info("Backed up corrupt prefs to \(backupURL.path, privacy: .public)")
    }
}
