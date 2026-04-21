import Foundation
import os

// MARK: - SettingsController

/// Single writer for the settings store. All mutations go through here.
/// Combines: Preferences (disk) + SettingsStore (memory) + update/command registries.
private let logger = Logger(subsystem: "com.clawd.onmac", category: "SettingsController")

final class SettingsController {

    struct UpdateResult {
        let status: Status
        let message: String?

        enum Status { case ok, error, noop }

        static let ok = UpdateResult(status: .ok, message: nil)
        static let noop = UpdateResult(status: .noop, message: nil)
        static func error(_ msg: String) -> UpdateResult {
            UpdateResult(status: .error, message: msg)
        }
    }

    typealias Validator = (Any, PreferencesSnapshot) -> Any?
    typealias Effect = (Any, PreferencesSnapshot) -> Void

    struct UpdateEntry {
        let validate: Validator?
        let effect: Effect?

        init(validate: Validator? = nil, effect: Effect? = nil) {
            self.validate = validate
            self.effect = effect
        }
    }

    typealias CommandHandler = (Any?, PreferencesSnapshot) async throws -> Void

    let store: SettingsStore
    private let prefsPath: URL
    private var locked: Bool

    private var updateRegistry: [String: UpdateEntry] = [:]
    private var commandRegistry: [String: CommandHandler] = [:]

    init(prefsPath: URL? = nil) {
        let path = prefsPath ?? Preferences.prefsPath()
        self.prefsPath = path

        let result = Preferences.load(from: path)
        self.locked = result.locked
        self.store = SettingsStore(result.snapshot)

        registerDefaultUpdates()
    }

    // MARK: - Read access

    func getSnapshot() -> PreferencesSnapshot {
        store.getSnapshot()
    }

    func get<T>(_ keyPath: KeyPath<PreferencesSnapshot, T>) -> T {
        store.get(keyPath)
    }

    @discardableResult
    func subscribe(_ fn: @escaping SettingsStore.Subscriber) -> UUID {
        store.subscribe(fn)
    }

    @discardableResult
    func subscribeKey<T: Equatable>(
        _ keyPath: KeyPath<PreferencesSnapshot, T>,
        handler: @escaping (T, PreferencesSnapshot) -> Void
    ) -> UUID {
        store.subscribeKey(keyPath, handler: handler)
    }

    // MARK: - Write access

    /// Single-field update (menu click, IPC, etc.)
    func applyUpdate(_ key: String, value: Any) -> UpdateResult {
        guard let partial = buildPartial(key: key, value: value) else {
            return .error("Unknown settings key: \(key)")
        }

        // Run validator if registered — use the coerced value
        var validatedValue = value
        if let entry = updateRegistry[key], let validate = entry.validate {
            let snapshot = store.getSnapshot()
            guard let coerced = validate(value, snapshot) else {
                return .error("Validation failed for \(key)")
            }
            validatedValue = coerced
        }

        // Rebuild partial with validated value
        let validatedPartial = buildPartial(key: key, value: validatedValue) ?? partial

        // Run pre-commit effect
        if let entry = updateRegistry[key], let effect = entry.effect {
            effect(validatedValue, store.getSnapshot())
        }

        let result = store.commit(validatedPartial)
        if result.changed {
            persist()
            return .ok
        }
        return .noop
    }

    /// Multi-field update (window bounds, mini state, etc.)
    func applyBulk(_ updates: [(key: String, value: Any)]) -> UpdateResult {
        var combined = PartialPreferences()
        let snapshot = store.getSnapshot()

        for (key, value) in updates {
            if let entry = updateRegistry[key], let validate = entry.validate {
                guard validate(value, snapshot) != nil else {
                    return .error("Validation failed for bulk key: \(key)")
                }
            }
            if let m = buildMutation(key: key, value: value) {
                combined.mutations.append(m)
            }
        }

        guard !combined.mutations.isEmpty else {
            return .noop
        }

        // Run effects
        for (key, value) in updates {
            if let entry = updateRegistry[key], let effect = entry.effect {
                effect(value, store.getSnapshot())
            }
        }

        let result = store.commit(combined)
        if result.changed {
            persist()
            return .ok
        }
        return .noop
    }

    /// Import external state without running effects (startup hydration).
    func hydrate(_ updates: [(key: String, value: Any)]) {
        var combined = PartialPreferences()

        for (key, value) in updates {
            if let entry = updateRegistry[key], let validate = entry.validate {
                guard validate(value, store.getSnapshot()) != nil else { continue }
            }
            if let m = buildMutation(key: key, value: value) {
                combined.mutations.append(m)
            }
        }

        if !combined.mutations.isEmpty {
            let result = store.commit(combined)
            if result.changed { persist() }
        }
    }

    /// Async command with side effects (install hooks, remove theme, etc.)
    func applyCommand(_ name: String, payload: Any? = nil) async -> UpdateResult {
        guard let handler = commandRegistry[name] else {
            return .error("Unknown command: \(name)")
        }
        do {
            try await handler(payload, store.getSnapshot())
            return .ok
        } catch {
            return .error("Command \(name) failed: \(error)")
        }
    }

    // MARK: - Registry

    func registerUpdate(_ key: String, entry: UpdateEntry) {
        updateRegistry[key] = entry
    }

    func registerCommand(_ name: String, handler: @escaping CommandHandler) {
        commandRegistry[name] = handler
    }

    // MARK: - Persistence

    func persist() {
        guard !locked else { return }
        do {
            try Preferences.save(store.getSnapshot(), to: prefsPath)
        } catch {
            logger.error("Failed to persist: \(error, privacy: .public)")
        }
    }

    // MARK: - Default update validators

    private func registerDefaultUpdates() {
        registerUpdate("lang", entry: UpdateEntry(validate: { value, _ in
            guard let s = value as? String, PreferencesSnapshot.validLangs.contains(s) else { return nil }
            return s
        }))

        registerUpdate("miniEdge", entry: UpdateEntry(validate: { value, _ in
            guard let s = value as? String, PreferencesSnapshot.validEdges.contains(s) else { return nil }
            return s
        }))

        registerUpdate("size", entry: UpdateEntry(validate: { value, _ in
            guard let s = value as? String else { return nil }
            if s == "S" || s == "M" || s == "L" { return s }
            if s.range(of: #"^P:\d+(?:\.\d+)?$"#, options: .regularExpression) != nil { return s }
            return nil
        }))

        registerUpdate("theme", entry: UpdateEntry(validate: { value, _ in
            guard let s = value as? String, !s.isEmpty else { return nil }
            return s
        }))
    }

    // MARK: - Partial builders

    private func buildPartial(key: String, value: Any) -> PartialPreferences? {
        guard let m = buildMutation(key: key, value: value) else { return nil }
        var p = PartialPreferences()
        p.mutations.append(m)
        return p
    }

    private func buildMutation(key: String, value: Any) -> (key: String, apply: PartialPreferences.Mutation)? {
        switch key {
        case "x": guard let v = value as? Double else { return nil }
            return (key, { $0.x = v })
        case "y": guard let v = value as? Double else { return nil }
            return (key, { $0.y = v })
        case "positionSaved": guard let v = value as? Bool else { return nil }
            return (key, { $0.positionSaved = v })
        case "size": guard let v = value as? String else { return nil }
            return (key, { $0.size = v })
        case "miniMode": guard let v = value as? Bool else { return nil }
            return (key, { $0.miniMode = v })
        case "miniEdge": guard let v = value as? String else { return nil }
            return (key, { $0.miniEdge = v })
        case "preMiniX": guard let v = value as? Double else { return nil }
            return (key, { $0.preMiniX = v })
        case "preMiniY": guard let v = value as? Double else { return nil }
            return (key, { $0.preMiniY = v })
        case "lang": guard let v = value as? String else { return nil }
            return (key, { $0.lang = v })
        case "showTray": guard let v = value as? Bool else { return nil }
            return (key, { $0.showTray = v })
        case "showDock": guard let v = value as? Bool else { return nil }
            return (key, { $0.showDock = v })
        case "manageClaudeHooksAutomatically": guard let v = value as? Bool else { return nil }
            return (key, { $0.manageClaudeHooksAutomatically = v })
        case "autoStartWithClaude": guard let v = value as? Bool else { return nil }
            return (key, { $0.autoStartWithClaude = v })
        case "openAtLogin": guard let v = value as? Bool else { return nil }
            return (key, { $0.openAtLogin = v })
        case "openAtLoginHydrated": guard let v = value as? Bool else { return nil }
            return (key, { $0.openAtLoginHydrated = v })
        case "bubbleFollowPet": guard let v = value as? Bool else { return nil }
            return (key, { $0.bubbleFollowPet = v })
        case "hideBubbles": guard let v = value as? Bool else { return nil }
            return (key, { $0.hideBubbles = v })
        case "showSessionId": guard let v = value as? Bool else { return nil }
            return (key, { $0.showSessionId = v })
        case "soundMuted": guard let v = value as? Bool else { return nil }
            return (key, { $0.soundMuted = v })
        case "theme": guard let v = value as? String else { return nil }
            return (key, { $0.theme = v })
        case "agents": guard let v = value as? [String: AgentConfig] else { return nil }
            return (key, { $0.agents = v })
        case "lastDisplayState": guard let v = value as? String else { return nil }
            return (key, { $0.lastDisplayState = v })
        case "sleepMode": guard let v = value as? String else { return nil }
            return (key, { $0.sleepMode = v })
        default:
            return nil
        }
    }
}
