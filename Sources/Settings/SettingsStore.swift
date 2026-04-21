import Foundation
import os

// MARK: - SettingsStore

/// In-memory state container with pub/sub. Only the controller calls `commit(_:)`.
/// Death-loop guard: shallow-compares each key before broadcasting.
private let logger = Logger(subsystem: "com.clawd.onmac", category: "SettingsStore")

final class SettingsStore {

    struct Change {
        let key: String
        let oldValue: Any?
        let newValue: Any?
    }

    struct Broadcast {
        let changes: [String: Any]
        let snapshot: PreferencesSnapshot
    }

    typealias Subscriber = (Broadcast) -> Void

    private let queue = DispatchQueue(label: "com.clawd.settings-store")
    private var _snapshot: PreferencesSnapshot
    private var subscribers: [UUID: Subscriber] = [:]
    private(set) var isDisposed = false

    private var snapshot: PreferencesSnapshot {
        get { queue.sync { _snapshot } }
        set { queue.sync { _snapshot = newValue } }
    }

    init(_ initial: PreferencesSnapshot) {
        self._snapshot = initial
    }

    func getSnapshot() -> PreferencesSnapshot {
        return snapshot
    }

    func get<T>(_ keyPath: KeyPath<PreferencesSnapshot, T>) -> T {
        return snapshot[keyPath: keyPath]
    }

    /// Subscribe to all changes. Returns an unsubscribe token.
    @discardableResult
    func subscribe(_ fn: @escaping Subscriber) -> UUID {
        let id = UUID()
        queue.sync { subscribers[id] = fn }
        return id
    }

    func unsubscribe(_ id: UUID) {
        queue.sync { _ = subscribers.removeValue(forKey: id) }
    }

    /// Subscribe to changes on a specific key path. Only fires when the value actually changes.
    @discardableResult
    func subscribeKey<T: Equatable>(
        _ keyPath: KeyPath<PreferencesSnapshot, T>,
        handler: @escaping (T, PreferencesSnapshot) -> Void
    ) -> UUID {
        var previousValue = snapshot[keyPath: keyPath]
        return subscribe { broadcast in
            let newVal = broadcast.snapshot[keyPath: keyPath]
            if newVal != previousValue {
                previousValue = newVal
                handler(newVal, broadcast.snapshot)
            }
        }
    }

    // MARK: - Commit (controller-only)

    struct CommitResult {
        let changed: Bool
        let changedKeys: Set<String>
    }

    /// Apply a partial update. Shallow-compares each field to avoid death loops.
    /// Only the SettingsController should call this.
    func commit(_ partial: PartialPreferences) -> CommitResult {
        guard !isDisposed else { return CommitResult(changed: false, changedKeys: []) }

        let (changes, broadcast, subs): ([String: Any], Broadcast?, [Subscriber]) = queue.sync {
            var changes: [String: Any] = [:]
            var newSnapshot = _snapshot

            for (key, apply) in partial.mutations {
                let old = _snapshot
                apply(&newSnapshot)
                if !areEqual(old, newSnapshot, key: key) {
                    changes[key] = key
                } else {
                    revert(&newSnapshot, from: old, key: key)
                }
            }

            guard !changes.isEmpty else {
                return ([:], nil, [])
            }

            _snapshot = newSnapshot
            let bc = Broadcast(changes: changes, snapshot: newSnapshot)
            return (changes, bc, Array(subscribers.values))
        }

        guard let broadcast = broadcast else {
            return CommitResult(changed: false, changedKeys: [])
        }

        for fn in subs {
            fn(broadcast)
        }

        return CommitResult(changed: true, changedKeys: Set(changes.keys))
    }

    func dispose() {
        isDisposed = true
        queue.sync { subscribers.removeAll() }
    }

    // MARK: - Equality helpers

    private func areEqual(_ a: PreferencesSnapshot, _ b: PreferencesSnapshot, key: String) -> Bool {
        switch key {
        case "x": return a.x == b.x
        case "y": return a.y == b.y
        case "positionSaved": return a.positionSaved == b.positionSaved
        case "size": return a.size == b.size
        case "miniMode": return a.miniMode == b.miniMode
        case "miniEdge": return a.miniEdge == b.miniEdge
        case "preMiniX": return a.preMiniX == b.preMiniX
        case "preMiniY": return a.preMiniY == b.preMiniY
        case "lang": return a.lang == b.lang
        case "showTray": return a.showTray == b.showTray
        case "showDock": return a.showDock == b.showDock
        case "manageClaudeHooksAutomatically": return a.manageClaudeHooksAutomatically == b.manageClaudeHooksAutomatically
        case "autoStartWithClaude": return a.autoStartWithClaude == b.autoStartWithClaude
        case "openAtLogin": return a.openAtLogin == b.openAtLogin
        case "openAtLoginHydrated": return a.openAtLoginHydrated == b.openAtLoginHydrated
        case "bubbleFollowPet": return a.bubbleFollowPet == b.bubbleFollowPet
        case "hideBubbles": return a.hideBubbles == b.hideBubbles
        case "showSessionId": return a.showSessionId == b.showSessionId
        case "soundMuted": return a.soundMuted == b.soundMuted
        case "theme": return a.theme == b.theme
        case "themeOverrides": return a.themeOverrides == b.themeOverrides
        case "themeVariant": return a.themeVariant == b.themeVariant
        case "agents": return a.agents == b.agents
        case "lastDisplayState": return a.lastDisplayState == b.lastDisplayState
        case "sleepMode": return a.sleepMode == b.sleepMode
        default:
            logger.warning("areEqual: unhandled key '\(key, privacy: .public)'")
            return true
        }
    }

    private func revert(_ target: inout PreferencesSnapshot, from source: PreferencesSnapshot, key: String) {
        switch key {
        case "x": target.x = source.x
        case "y": target.y = source.y
        case "positionSaved": target.positionSaved = source.positionSaved
        case "size": target.size = source.size
        case "miniMode": target.miniMode = source.miniMode
        case "miniEdge": target.miniEdge = source.miniEdge
        case "preMiniX": target.preMiniX = source.preMiniX
        case "preMiniY": target.preMiniY = source.preMiniY
        case "lang": target.lang = source.lang
        case "showTray": target.showTray = source.showTray
        case "showDock": target.showDock = source.showDock
        case "manageClaudeHooksAutomatically": target.manageClaudeHooksAutomatically = source.manageClaudeHooksAutomatically
        case "autoStartWithClaude": target.autoStartWithClaude = source.autoStartWithClaude
        case "openAtLogin": target.openAtLogin = source.openAtLogin
        case "openAtLoginHydrated": target.openAtLoginHydrated = source.openAtLoginHydrated
        case "bubbleFollowPet": target.bubbleFollowPet = source.bubbleFollowPet
        case "hideBubbles": target.hideBubbles = source.hideBubbles
        case "showSessionId": target.showSessionId = source.showSessionId
        case "soundMuted": target.soundMuted = source.soundMuted
        case "theme": target.theme = source.theme
        case "themeOverrides": target.themeOverrides = source.themeOverrides
        case "themeVariant": target.themeVariant = source.themeVariant
        case "agents": target.agents = source.agents
        case "lastDisplayState": target.lastDisplayState = source.lastDisplayState
        case "sleepMode": target.sleepMode = source.sleepMode
        default:
            logger.warning("revert: unhandled key '\(key, privacy: .public)'")
            break
        }
    }
}

// MARK: - PartialPreferences

/// Type-safe partial update builder.
struct PartialPreferences {
    typealias Mutation = (inout PreferencesSnapshot) -> Void
    var mutations: [(key: String, apply: Mutation)] = []

    mutating func set<T>(_ keyPath: WritableKeyPath<PreferencesSnapshot, T>, to value: T, key: String) {
        mutations.append((key: key, apply: { $0[keyPath: keyPath] = value }))
    }

    static func single<T>(_ keyPath: WritableKeyPath<PreferencesSnapshot, T>, value: T, key: String) -> PartialPreferences {
        var p = PartialPreferences()
        p.set(keyPath, to: value, key: key)
        return p
    }
}
