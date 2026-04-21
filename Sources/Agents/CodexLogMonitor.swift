import Foundation
import os

private let logger = Logger(subsystem: "com.clawd.ClawdOnMac", category: "CodexMonitor")

private let kPollInterval: TimeInterval = 1.5
private let kStaleThreshold: TimeInterval = 300
private let kSkipMtimeThreshold: TimeInterval = 120
private let kMaxTrackedFiles = 50
private let kMaxPartialBytes = 65536
private let kApprovalHeuristicInterval: TimeInterval = 2.0
private let kRecentDayDirCacheInterval: TimeInterval = 3600

private let kEventMap: [String: String] = [
    "session_meta": "idle",
    "event_msg:task_started": "thinking",
    "event_msg:user_message": "thinking",
    "event_msg:exec_command_end": "working",
    "event_msg:patch_apply_end": "working",
    "event_msg:custom_tool_call_output": "working",
    "response_item:function_call": "working",
    "response_item:custom_tool_call": "working",
    "response_item:web_search_call": "working",
    "event_msg:task_complete": "attention",
    "event_msg:context_compacted": "sweeping",
    "event_msg:turn_aborted": "idle",
    "event_msg:turn_completed": "codex-turn-end",
]

// MARK: - Tracked file state

private struct TrackedFile {
    var offset: UInt64
    let sessionId: String
    let filePath: String
    var cwd: String
    var sessionTitle: String?
    var lastEventTime: Date
    var lastState: String?
    var partial: String
    var hadToolUse: Bool
    var approvalTimer: DispatchWorkItem?
}

// MARK: - CodexLogMonitor

class CodexLogMonitor {

    /// (sessionId, state, event, extra)
    var onStateChange: ((String, String, String, [String: String]) -> Void)?

    private var timer: Timer?
    private var tracked: [String: TrackedFile] = [:]
    private let baseDir: String
    private let fm = FileManager.default
    private var startedAt: Date = Date()

    private var recentDayDirsCache: [String] = []
    private var recentDayDirsCacheAt: Date = .distantPast
    private var recentDayDirsCacheDateKey: String = ""

    init() {
        let home = fm.homeDirectoryForCurrentUser.path
        baseDir = (home as NSString).appendingPathComponent(".codex/sessions")
    }

    func start() {
        guard timer == nil else { return }
        startedAt = Date()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: kPollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for (_, entry) in tracked {
            entry.approvalTimer?.cancel()
        }
        tracked.removeAll()
    }

    // MARK: - Poll cycle

    private func poll() {
        let dirs = sessionDirs()
        let now = Date()
        for dir in dirs {
            guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in contents {
                guard file.hasPrefix("rollout-"), file.hasSuffix(".jsonl") else { continue }
                let filePath = (dir as NSString).appendingPathComponent(file)
                if tracked[filePath] == nil {
                    guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                          let mtime = attrs[.modificationDate] as? Date else { continue }
                    if now.timeIntervalSince(mtime) > kSkipMtimeThreshold { continue }
                }
                pollFile(filePath: filePath, fileName: file)
            }
        }
        cleanStaleFiles()
    }

    // MARK: - Session directories

    private func sessionDirs() -> [String] {
        var dirs: [String] = []
        var seen = Set<String>()
        let add = { (dir: String) in
            guard !seen.contains(dir) else { return }
            seen.insert(dir)
            dirs.append(dir)
        }

        let now = Date()
        let cal = Calendar.current
        for daysAgo in 0...2 {
            guard let date = cal.date(byAdding: .day, value: -daysAgo, to: now) else { continue }
            let y = cal.component(.year, from: date)
            let m = cal.component(.month, from: date)
            let d = cal.component(.day, from: date)
            let dir = String(format: "%@/%d/%02d/%02d", baseDir, y, m, d)
            add(dir)
        }

        for dir in cachedRecentExistingDayDirs(limit: 7) {
            add(dir)
        }

        return dirs
    }

    private func cachedRecentExistingDayDirs(limit: Int) -> [String] {
        let now = Date()
        let dateKey = localDateKey()
        let cacheStale = now.timeIntervalSince(recentDayDirsCacheAt) > kRecentDayDirCacheInterval
        let dayChanged = dateKey != recentDayDirsCacheDateKey

        if recentDayDirsCache.isEmpty || cacheStale || dayChanged {
            recentDayDirsCache = recentExistingDayDirs(limit: limit)
            recentDayDirsCacheAt = now
            recentDayDirsCacheDateKey = dateKey
        }
        return Array(recentDayDirsCache.prefix(limit))
    }

    private func localDateKey() -> String {
        let cal = Calendar.current
        let now = Date()
        let y = cal.component(.year, from: now)
        let m = cal.component(.month, from: now)
        let d = cal.component(.day, from: now)
        return String(format: "%d-%02d-%02d", y, m, d)
    }

    private func recentExistingDayDirs(limit: Int) -> [String] {
        var out: [String] = []
        guard let years = try? fm.contentsOfDirectory(atPath: baseDir)
            .filter({ $0.range(of: #"^\d{4}$"#, options: .regularExpression) != nil })
            .sorted(by: >) else { return out }

        for y in years {
            let yPath = (baseDir as NSString).appendingPathComponent(y)
            guard let months = try? fm.contentsOfDirectory(atPath: yPath)
                .filter({ $0.range(of: #"^\d{2}$"#, options: .regularExpression) != nil })
                .sorted(by: >) else { continue }
            for m in months {
                let mPath = (yPath as NSString).appendingPathComponent(m)
                guard let days = try? fm.contentsOfDirectory(atPath: mPath)
                    .filter({ $0.range(of: #"^\d{2}$"#, options: .regularExpression) != nil })
                    .sorted(by: >) else { continue }
                for d in days {
                    out.append((mPath as NSString).appendingPathComponent(d))
                    if out.count >= limit { return out }
                }
            }
        }
        return out
    }

    // MARK: - File polling

    private func pollFile(filePath: String, fileName: String) {
        guard let attrs = try? fm.attributesOfItem(atPath: filePath),
              let fileSize = attrs[.size] as? UInt64 else { return }

        if tracked[filePath] == nil {
            guard let sessionId = extractSessionId(from: fileName) else { return }
            if tracked.count >= kMaxTrackedFiles {
                cleanStaleFiles()
                if tracked.count >= kMaxTrackedFiles { return }
            }
            tracked[filePath] = TrackedFile(
                offset: 0,
                sessionId: "codex:" + sessionId,
                filePath: filePath,
                cwd: "",
                sessionTitle: nil,
                lastEventTime: Date(),
                lastState: nil,
                partial: "",
                hadToolUse: false
            )
        }

        guard var entry = tracked[filePath] else { return }
        guard fileSize > entry.offset else { return }

        guard let handle = FileHandle(forReadingAtPath: filePath) else {
            // File was deleted — remove from tracking immediately
            tracked.removeValue(forKey: filePath)
            return
        }
        defer { handle.closeFile() }
        handle.seek(toFileOffset: entry.offset)
        let data = handle.readData(ofLength: Int(fileSize - entry.offset))
        entry.offset = fileSize

        guard let chunk = String(data: data, encoding: .utf8) else {
            tracked[filePath] = entry
            return
        }

        let text = entry.partial + chunk
        var lines = text.components(separatedBy: "\n")
        let remainder = lines.removeLast()
        entry.partial = remainder.utf8.count > kMaxPartialBytes ? "" : remainder

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            processLine(trimmed, tracked: &entry)
        }

        tracked[filePath] = entry
    }

    // MARK: - Line processing

    private func processLine(_ line: String, tracked: inout TrackedFile) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let ts = obj["timestamp"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: ts),
               date.timeIntervalSince(startedAt) < -kPollInterval {
                return
            }
        }

        let type = obj["type"] as? String ?? ""
        let payload = obj["payload"] as? [String: Any]
        let subtype = payload?["type"] as? String ?? ""

        let key = subtype.isEmpty ? type : "\(type):\(subtype)"

        if type == "session_meta", let cwd = payload?["cwd"] as? String {
            tracked.cwd = cwd
        }

        if let summary = extractSessionTitle(obj) {
            tracked.sessionTitle = summary
        }

        if key == "event_msg:exec_command_end" || key == "response_item:function_call_output" {
            // Command finished — cancel pending approval timer
            tracked.approvalTimer?.cancel()
            tracked.approvalTimer = nil
        }

        guard let state = kEventMap[key] else { return }

        if key == "event_msg:task_started" {
            tracked.hadToolUse = false
        }
        if key == "response_item:function_call" {
            tracked.hadToolUse = true

            // Approval heuristic: start 2s timer. If no exec_command_end arrives,
            // assume Codex is waiting for user approval
            tracked.approvalTimer?.cancel()
            let cmd = extractShellCommand(payload)
            let sid = tracked.sessionId
            let item = DispatchWorkItem { [weak self] in
                self?.onStateChange?(sid, "codex-permission", key, ["command": cmd ?? ""])
            }
            tracked.approvalTimer = item
            DispatchQueue.main.asyncAfter(deadline: .now() + kApprovalHeuristicInterval, execute: item)
        }

        if state == "codex-turn-end" {
            let resolved = tracked.hadToolUse ? "attention" : "idle"
            tracked.hadToolUse = false
            tracked.lastState = resolved
            tracked.lastEventTime = Date()
            onStateChange?(tracked.sessionId, resolved, key, [:])
            return
        }

        if state == tracked.lastState && state == "working" { return }
        tracked.lastState = state
        tracked.lastEventTime = Date()

        let sid = tracked.sessionId
        logger.debug("codex state: \(state, privacy: .public) event: \(key, privacy: .public) session: \(sid, privacy: .public)")
        onStateChange?(sid, state, key, [:])
    }

    private func extractSessionTitle(_ obj: [String: Any]) -> String? {
        guard let payload = obj["payload"] as? [String: Any],
              obj["type"] as? String == "turn_context",
              let summary = payload["summary"] as? String else { return nil }
        let trimmed = summary.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "none" || trimmed == "auto" { return nil }
        return trimmed
    }

    private func extractShellCommand(_ payload: [String: Any]?) -> String? {
        guard let payload = payload else { return nil }
        let name = payload["name"] as? String ?? ""
        guard name == "shell_command" || name == "exec_command" else { return nil }
        if let cmd = payload["cmd"] as? String { return cmd }
        if let args = payload["arguments"] as? [String: Any],
           let cmd = args["command"] as? String { return cmd }
        return nil
    }

    // MARK: - Session ID extraction

    private func extractSessionId(from fileName: String) -> String? {
        let base = fileName.replacingOccurrences(of: ".jsonl", with: "")
        let parts = base.split(separator: "-")
        guard parts.count >= 10 else { return nil }
        return parts.suffix(5).joined(separator: "-")
    }

    // MARK: - Stale cleanup

    private func cleanStaleFiles() {
        let now = Date()
        var toRemove: [String] = []
        for (path, entry) in tracked {
            if now.timeIntervalSince(entry.lastEventTime) > kStaleThreshold {
                toRemove.append(path)
                logger.info("stale codex session: \(entry.sessionId, privacy: .public)")
                onStateChange?(entry.sessionId, "sleeping", "stale-cleanup", [:])
            }
        }
        for path in toRemove {
            tracked.removeValue(forKey: path)
        }
    }
}
