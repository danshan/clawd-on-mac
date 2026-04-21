import Foundation

// MARK: - State enums

enum PetState: String, Codable, Sendable {
    case idle
    case thinking
    case working
    case juggling
    case sweeping
    case error
    case attention
    case notification
    case carrying
    case sleeping
    case waking
    case dozing
    case yawning
    case collapsing
    case mini_idle
    case mini_enter
    case mini_peek
    case mini_alert
    case mini_happy
    case mini_crabwalk
    case mini_enter_sleep
    case mini_sleep
    case mini_working
}

enum DisplayState: String, Sendable {
    case idle
    case thinking
    case working
    case juggling
    case sweeping
    case error
    case attention
    case notification
    case carrying
    case sleeping
    case waking
    case dozing
    case yawning
    case collapsing
    case mini_idle
    case mini_enter
    case mini_peek
    case mini_alert
    case mini_happy
    case mini_crabwalk
    case mini_enter_sleep
    case mini_sleep
    case mini_working
    case none
}

// MARK: - Session

enum SessionBadge: String, Sendable {
    case running
    case done
    case interrupted
    case idle
}

struct SessionState: Sendable {
    let sessionId: String
    var state: PetState
    var event: String?
    var sourcePid: Int32?
    var cwd: String?
    var agentId: String?
    var displayHint: String?
    var lastUpdate: Date = Date()
    var recentEvents: [String] = []

    static let maxRecentEvents = 8

    mutating func pushEvent(_ event: String) {
        recentEvents.append(event)
        if recentEvents.count > Self.maxRecentEvents {
            recentEvents.removeFirst()
        }
    }

    var badge: SessionBadge {
        guard let last = recentEvents.last else { return .idle }
        switch last {
        case "init", "start", "tool_start", "PreToolUse", "PostToolUse":
            return .running
        case "exit", "done", "complete":
            return .done
        case "interrupt", "error", "timeout":
            return .interrupted
        default:
            return state == .idle ? .idle : .running
        }
    }
}

// MARK: - Timings

struct Timings: Codable, Sendable {
    var minDisplay: [String: Int] = [:]
    var autoReturn: [String: Int] = [:]
    var yawnDuration: Int = 3000
    var wakeDuration: Int = 1500
    var deepSleepTimeout: Int = 600_000
    var mouseIdleTimeout: Int = 20_000
    var mouseSleepTimeout: Int = 60_000
    var staleSessionTimeout: TimeInterval = 600
    var staleCleanupInterval: TimeInterval = 30
    var maxSessions: Int = 50
}

// MARK: - Sleep mode

enum SleepMode: Sendable {
    case full    // idle → yawning → dozing → collapsing → sleeping
    case direct  // idle → sleeping (no animation)
}

// MARK: - State change callback

typealias StateChangeCallback = @Sendable (DisplayState, DisplayState) -> Void

// MARK: - PetStateActor

actor PetStateActor {

    private var sessions: [String: SessionState] = [:]
    private var displayState: DisplayState = .idle
    private var miniMode: Bool = false
    private var doNotDisturb: Bool = false
    private var mousePosition: CGPoint = .zero
    private var lastMouseMoveTime: Date = Date()

    private var autoReturnTimers: [String: Task<Void, Never>] = [:]
    private var sleepSequenceTask: Task<Void, Never>?
    private var staleCleanupTask: Task<Void, Never>?
    private var wakePollTask: Task<Void, Never>?

    private var miniTransitioning: Bool = false
    private var sleepMode: SleepMode = .full

    private let timings: Timings
    private var displayHintMap: [String: String] = [:]

    /// Callback fired on display state change (old, new).
    var onStateChange: StateChangeCallback?

    private let STATE_PRIORITY: [PetState: Int] = [
        .error: 8, .notification: 7, .sweeping: 6, .attention: 5,
        .carrying: 4, .working: 3, .juggling: 3, .thinking: 2,
        .idle: 1, .sleeping: 0
    ]

    private let ONESHOT_STATES: Set<PetState> = [
        .attention, .error, .sweeping, .notification, .carrying
    ]

    // Map incoming state strings to visual overrides
    private let VISUAL_OVERRIDES: [String: PetState] = [
        "checking": .sweeping,
        "downloading": .carrying
    ]

    init(timings: Timings = Timings()) {
        self.timings = timings
        startStaleCleanup()
    }

    deinit {
        staleCleanupTask?.cancel()
        wakePollTask?.cancel()
        sleepSequenceTask?.cancel()
        for timer in autoReturnTimers.values { timer.cancel() }
    }

    // MARK: - Session updates

    func updateSession(
        _ sessionId: String,
        state: String,
        event: String?,
        sourcePid: Int32?,
        cwd: String?,
        agentId: String?,
        displayHint: String? = nil
    ) {
        if doNotDisturb { return }

        // PermissionRequest triggers notification visual without mutating session state,
        // preserving working/thinking for when the permission resolves
        if event == "PermissionRequest" {
            let old = displayState
            let new: DisplayState = .notification
            if old != new {
                displayState = new
                notifyStateChange(old: old, new: new)
            }
            return
        }

        if state == "session_end" {
            sessions.removeValue(forKey: sessionId)
            _ = resolveDisplayState()
            return
        }

        // Map visual override states
        let resolvedState = VISUAL_OVERRIDES[state] ?? PetState(rawValue: state) ?? .idle
        let petState = resolvedState

        var session = sessions[sessionId] ?? SessionState(
            sessionId: sessionId,
            state: petState,
            event: event,
            sourcePid: sourcePid,
            cwd: cwd,
            agentId: agentId,
            displayHint: displayHint
        )

        session.state = petState
        session.event = event
        session.sourcePid = sourcePid
        session.cwd = cwd
        session.agentId = agentId
        session.displayHint = displayHint
        session.lastUpdate = Date()
        if let event = event {
            session.pushEvent(event)
        }

        sessions[sessionId] = session

        // Evict oldest idle sessions if over limit
        if sessions.count > timings.maxSessions {
            let idle = sessions
                .filter { $0.value.state == .idle }
                .sorted { $0.value.lastUpdate < $1.value.lastUpdate }
            for entry in idle.prefix(sessions.count - timings.maxSessions) {
                sessions.removeValue(forKey: entry.key)
                autoReturnTimers[entry.key]?.cancel()
                autoReturnTimers.removeValue(forKey: entry.key)
            }
        }

        // Cancel sleep if a session becomes active
        if petState != .idle && petState != .sleeping {
            cancelSleepSequence()
        }

        _ = resolveDisplayState()

        if ONESHOT_STATES.contains(petState) {
            scheduleAutoReturn(sessionId: sessionId, state: petState)
        }
    }

    // MARK: - Mouse tracking + sleep

    func updateMousePosition(_ position: CGPoint) {
        let oldPosition = mousePosition
        mousePosition = position
        lastMouseMoveTime = Date()

        let moved = hypot(position.x - oldPosition.x, position.y - oldPosition.y) > 2

        // Wake from sleep on mouse movement
        if moved && isSleeping() {
            wakeUp()
            return
        }

        // Reset sleep timer on movement when idle
        if moved && displayState == .idle {
            startSleepSequence()
        }
    }

    private func isSleeping() -> Bool {
        switch displayState {
        case .sleeping, .dozing, .collapsing, .yawning:
            return true
        default:
            return false
        }
    }

    private func wakeUp() {
        cancelSleepSequence()
        let old = displayState
        displayState = .waking
        notifyStateChange(old: old, new: .waking)

        sleepSequenceTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timings.wakeDuration) * 1_000_000)
            guard !Task.isCancelled else { return }
            let old = displayState
            displayState = .idle
            notifyStateChange(old: old, new: .idle)
            startSleepSequence()
        }
    }

    func startSleepSequence() {
        cancelSleepSequence()

        guard sessions.isEmpty || sessions.allSatisfy({ $0.value.state == .idle }) else {
            return
        }

        sleepSequenceTask = Task {
            // Wait for mouse idle timeout
            try? await Task.sleep(nanoseconds: UInt64(timings.mouseIdleTimeout) * 1_000_000)
            guard !Task.isCancelled else { return }

            if sleepMode == .direct {
                let old = displayState
                displayState = .sleeping
                notifyStateChange(old: old, new: .sleeping)
                startWakePoll()
                return
            }

            // Full sleep: yawning
            var old = displayState
            displayState = .yawning
            notifyStateChange(old: old, new: .yawning)

            try? await Task.sleep(nanoseconds: UInt64(timings.yawnDuration) * 1_000_000)
            guard !Task.isCancelled else { return }

            // dozing
            old = displayState
            displayState = .dozing
            notifyStateChange(old: old, new: .dozing)

            try? await Task.sleep(nanoseconds: UInt64(timings.mouseSleepTimeout) * 1_000_000)
            guard !Task.isCancelled else { return }

            // collapsing
            old = displayState
            displayState = .collapsing
            notifyStateChange(old: old, new: .collapsing)

            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }

            // sleeping
            old = displayState
            displayState = .sleeping
            notifyStateChange(old: old, new: .sleeping)

            startWakePoll()
        }
    }

    private func cancelSleepSequence() {
        sleepSequenceTask?.cancel()
        sleepSequenceTask = nil
        wakePollTask?.cancel()
        wakePollTask = nil
    }

    /// Poll for mouse movement during deep sleep to wake up.
    private func startWakePoll() {
        wakePollTask?.cancel()
        wakePollTask = Task {
            let pollInterval: UInt64 = 1_000_000_000 // 1s
            while !Task.isCancelled && displayState == .sleeping {
                try? await Task.sleep(nanoseconds: pollInterval)
                guard !Task.isCancelled else { return }
                if Date().timeIntervalSince(lastMouseMoveTime) < 2.0 {
                    wakeUp()
                    return
                }
            }
        }
    }

    // MARK: - Stale session cleanup

    private func startStaleCleanup() {
        staleCleanupTask = Task { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.timings.staleCleanupInterval) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self.cleanupStaleSessions()
            }
        }
    }

    private func cleanupStaleSessions() {
        let now = Date()
        let staleTimeout = timings.staleSessionTimeout
        var removed = false

        for (id, session) in sessions {
            if now.timeIntervalSince(session.lastUpdate) > staleTimeout {
                sessions.removeValue(forKey: id)
                autoReturnTimers[id]?.cancel()
                autoReturnTimers.removeValue(forKey: id)
                removed = true
            }
        }

        if removed {
            _ = resolveDisplayState()
        }
    }

    // MARK: - Mode toggles

    func toggleMiniMode() {
        miniMode.toggle()
        _ = resolveDisplayState()
    }

    func setMiniMode(_ enabled: Bool) {
        miniMode = enabled
        _ = resolveDisplayState()
    }

    func toggleDoNotDisturb() {
        doNotDisturb.toggle()
        if doNotDisturb {
            sessions.removeAll()
            cancelSleepSequence()
            _ = resolveDisplayState()
        }
    }

    // MARK: - Display hint map

    func setDisplayHintMap(_ map: [String: String]) {
        displayHintMap = map
    }

    // MARK: - Hitbox configuration

    private var wideSVGs: Set<String> = []
    private var sleepingSVGs: Set<String> = []
    private var hitBoxes: [String: HitBox] = [:]

    func setHitboxConfig(hitBoxes: [String: HitBox], wideSVGs: [String], sleepingSVGs: [String]) {
        self.hitBoxes = hitBoxes
        self.wideSVGs = Set(wideSVGs)
        self.sleepingSVGs = Set(sleepingSVGs)
    }

    /// Returns the appropriate hitbox for the given SVG filename.
    func hitboxForSVG(_ svgFilename: String) -> HitBox? {
        let name = (svgFilename as NSString).lastPathComponent
        if sleepingSVGs.contains(name) {
            return hitBoxes["sleeping"] ?? hitBoxes["default"]
        } else if wideSVGs.contains(name) {
            return hitBoxes["wide"] ?? hitBoxes["default"]
        }
        return hitBoxes["default"]
    }

    // MARK: - State resolution

    @discardableResult
    func resolveDisplayState() -> DisplayState {
        if miniMode {
            let new = resolveMiniDisplayState()
            if displayState != new {
                let old = displayState
                displayState = new
                notifyStateChange(old: old, new: new)
            }
            return displayState
        }

        // Don't override sleep sequence states
        if isSleeping() { return displayState }

        var highestPriority = -1
        var currentState: PetState = .idle
        var winningSession: SessionState?

        for (_, session) in sessions {
            let priority = STATE_PRIORITY[session.state] ?? 0
            if priority > highestPriority {
                highestPriority = priority
                currentState = session.state
                winningSession = session
            }
        }

        var newDisplay = mapToDisplayState(currentState)

        // Apply display hint override if available
        if let hint = winningSession?.displayHint, let mapped = displayHintMap[hint] {
            if let overrideState = DisplayState(rawValue: mapped) {
                newDisplay = overrideState
            }
        }

        if displayState != newDisplay {
            let old = displayState
            displayState = newDisplay
            notifyStateChange(old: old, new: newDisplay)

            // Start sleep timer if returning to idle
            if newDisplay == .idle {
                startSleepSequence()
            }
        }

        return displayState
    }

    private func resolveMiniDisplayState() -> DisplayState {
        guard !sessions.isEmpty else { return .mini_idle }

        var highestPriority = -1
        var topState: PetState = .idle

        for (_, session) in sessions {
            let priority = STATE_PRIORITY[session.state] ?? 0
            if priority > highestPriority {
                highestPriority = priority
                topState = session.state
            }
        }

        switch topState {
        case .error: return .mini_alert
        case .notification: return .mini_alert
        case .attention: return .mini_happy
        case .working, .thinking, .juggling: return .mini_working
        default: return .mini_idle
        }
    }

    private func mapToDisplayState(_ state: PetState) -> DisplayState {
        switch state {
        case .idle: return .idle
        case .thinking: return .thinking
        case .working: return .working
        case .juggling: return .juggling
        case .sweeping: return .sweeping
        case .error: return .error
        case .attention: return .attention
        case .notification: return .notification
        case .carrying: return .carrying
        case .sleeping: return .sleeping
        case .waking: return .waking
        case .dozing: return .dozing
        case .yawning: return .yawning
        case .collapsing: return .collapsing
        default: return .idle
        }
    }

    private func isMiniCompatibleState(_ state: PetState) -> Bool {
        switch state {
        case .idle, .thinking, .working, .notification, .attention: return true
        default: return false
        }
    }

    private func scheduleAutoReturn(sessionId: String, state: PetState) {
        let delay = timings.autoReturn[state.rawValue] ?? 4000

        autoReturnTimers[sessionId]?.cancel()
        autoReturnTimers[sessionId] = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            guard !Task.isCancelled else { return }
            if sessions[sessionId]?.state == state {
                sessions.removeValue(forKey: sessionId)
                _ = resolveDisplayState()
            }
        }
    }

    private func notifyStateChange(old: DisplayState, new: DisplayState) {
        guard old != new else { return }
        onStateChange?(old, new)
    }

    // MARK: - Queries

    func getCurrentDisplayState() -> DisplayState {
        return displayState
    }

    func isMiniMode() -> Bool {
        return miniMode
    }

    func isDoNotDisturb() -> Bool {
        return doNotDisturb
    }

    func getActiveSessions() -> [SessionState] {
        return Array(sessions.values)
    }

    func getActiveSessionCount() -> Int {
        return sessions.count
    }

    /// Get the winning session (highest priority).
    func getWinningSession() -> SessionState? {
        var best: SessionState?
        var bestPriority = -1
        for (_, s) in sessions {
            let p = STATE_PRIORITY[s.state] ?? 0
            if p > bestPriority {
                bestPriority = p
                best = s
            }
        }
        return best
    }

    /// Number of active working sessions (for tier selection).
    func getWorkingSessionCount() -> Int {
        return sessions.values.filter { $0.state == .working || $0.state == .juggling }.count
    }

    func setSleepMode(_ mode: SleepMode) {
        sleepMode = mode
    }

    /// Restore display state from saved preferences (startup only).
    /// Only restores states that make sense without active sessions.
    func restoreDisplayState(_ saved: String) {
        guard let state = DisplayState(rawValue: saved) else { return }
        switch state {
        case .sleeping:
            displayState = .sleeping
            startWakePoll()
            notifyStateChange(old: .idle, new: .sleeping)
        default:
            // All other states either require active sessions or are transient;
            // fall through to idle (already default)
            break
        }
    }
}