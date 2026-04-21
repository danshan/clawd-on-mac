import Foundation
import os

private let logger = Logger(subsystem: "com.clawd.ClawdOnMac", category: "GeminiMonitor")

private let pollInterval: TimeInterval = 1.5
private let deferCompletionDelay: TimeInterval = 4.0
private let staleThreshold: TimeInterval = 300
private let skipMtimeThreshold: TimeInterval = 120

// MARK: - Session JSON models

private struct GeminiSession: Decodable {
    let sessionId: String?
    let messages: [GeminiMessage]?
}

private struct GeminiMessage: Decodable {
    let type: String
    let content: String?
    let toolCalls: [GeminiToolCall]?
}

private struct GeminiToolCall: Decodable {
    let name: String?
    let status: String?
}

private struct GeminiProjects: Decodable {
    let projects: [String: String]?  // physPath → dirName
}

// MARK: - Per-file tracking state

private struct TrackedFile {
    var mtime: TimeInterval
    var sessionId: String
    var lastState: String?
    var lastEventTime: Date
    var msgCount: Int
    var hasTools: Bool
    var cwd: String
    var turnHasTools: Bool
}

// MARK: - GeminiLogMonitor

class GeminiLogMonitor {

    var onStateChange: ((String, String, String) -> Void)?

    private let baseDir: String
    private var timer: Timer?
    private var tracked: [String: TrackedFile] = [:]
    private var pendingCompletions: [String: DispatchWorkItem] = [:]
    private var cwdMap: [String: String]?
    private var projectsMtime: TimeInterval = 0

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.baseDir = (home as NSString).appendingPathComponent(".gemini/tmp")
    }

    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for item in pendingCompletions.values { item.cancel() }
        pendingCompletions.removeAll()
        tracked.removeAll()
    }

    // MARK: - CWD resolution

    private func loadCwdMap() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let projectsPath = (home as NSString).appendingPathComponent(".gemini/projects.json")
        let fm = FileManager.default

        guard let attrs = try? fm.attributesOfItem(atPath: projectsPath),
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else {
            return
        }

        guard cwdMap == nil || mtime != projectsMtime else { return }
        projectsMtime = mtime

        guard let data = fm.contents(atPath: projectsPath),
              let projects = try? JSONDecoder().decode(GeminiProjects.self, from: data),
              let mapping = projects.projects else {
            return
        }

        // projects.json maps physPath → dirName; we need dirName → physPath
        var map: [String: String] = [:]
        for (physPath, dirName) in mapping {
            map[dirName] = physPath
        }
        cwdMap = map
    }

    // MARK: - Polling

    // All mutable state is accessed exclusively on the main thread (Timer + RunLoop)
    private func poll() {
        guard timer != nil else { return }
        loadCwdMap()

        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: baseDir) else { return }

        let now = Date().timeIntervalSince1970

        for projectDir in projectDirs {
            let chatsDir = (baseDir as NSString)
                .appendingPathComponent(projectDir)
                .appending("/chats")

            guard let files = try? fm.contentsOfDirectory(atPath: chatsDir) else { continue }

            for file in files {
                guard file.hasPrefix("session-"), file.hasSuffix(".json") else { continue }
                let filePath = (chatsDir as NSString).appendingPathComponent(file)

                if tracked[filePath] == nil {
                    guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                          let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else {
                        continue
                    }
                    if now - mtime > skipMtimeThreshold { continue }
                }

                pollFile(filePath, projectDir: projectDir)
            }
        }

        cleanStale()
    }

    private func pollFile(_ filePath: String, projectDir: String) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: filePath),
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else {
            return
        }

        if let existing = tracked[filePath], existing.mtime == mtime { return }

        guard let rawData = fm.contents(atPath: filePath),
              let session = try? JSONDecoder().decode(GeminiSession.self, from: rawData) else {
            return
        }

        processSession(filePath, data: session, projectDir: projectDir, mtime: mtime)
    }

    // MARK: - Session processing

    private func processSession(_ filePath: String, data: GeminiSession, projectDir: String, mtime: TimeInterval) {
        guard let msgs = data.messages, !msgs.isEmpty else { return }
        let last = msgs[msgs.count - 1]

        let tools = last.type == "gemini" ? last.toolCalls : nil
        let hasTools = tools.map { !$0.isEmpty } ?? false

        if last.type == "user" {
            cancelPending(filePath)
            tracked[filePath]?.turnHasTools = false
            emitState(filePath, data: data, projectDir: projectDir, mtime: mtime,
                      msgCount: msgs.count, hasTools: false,
                      state: "thinking", event: "UserPromptSubmit")
        } else if last.type == "gemini" {
            if hasTools {
                cancelPending(filePath)
                let lastTool = tools!.last!
                let isError = lastTool.status == "error"
                let state = isError ? "error" : "attention"
                let event = isError ? "PostToolUseFailure" : "Stop"
                emitState(filePath, data: data, projectDir: projectDir, mtime: mtime,
                          msgCount: msgs.count, hasTools: true,
                          state: state, event: event)
                tracked[filePath]?.turnHasTools = true
            } else if tracked[filePath]?.turnHasTools == true {
                tracked[filePath]?.mtime = mtime
                tracked[filePath]?.msgCount = msgs.count
                tracked[filePath]?.hasTools = false
                tracked[filePath]?.lastEventTime = Date()
            } else {
                deferCompletion(filePath, data: data, projectDir: projectDir,
                                mtime: mtime, msgCount: msgs.count)
            }
        }
    }

    // MARK: - State emission with dedup

    private func emitState(_ filePath: String, data: GeminiSession, projectDir: String,
                           mtime: TimeInterval, msgCount: Int, hasTools: Bool,
                           state: String, event: String) {
        if let existing = tracked[filePath],
           existing.lastState == state,
           existing.msgCount == msgCount,
           existing.hasTools == hasTools {
            tracked[filePath]?.mtime = mtime
            tracked[filePath]?.lastEventTime = Date()
            return
        }

        let sessionId = "gemini:" + (data.sessionId ?? fileBaseName(filePath))
        let cwd = cwdMap?[projectDir] ?? ""

        let prevTurnHasTools = tracked[filePath]?.turnHasTools ?? false
        tracked[filePath] = TrackedFile(
            mtime: mtime, sessionId: sessionId, lastState: state,
            lastEventTime: Date(), msgCount: msgCount, hasTools: hasTools,
            cwd: cwd, turnHasTools: prevTurnHasTools
        )

        logger.info("state=\(state) event=\(event) session=\(sessionId)")
        onStateChange?(sessionId, state, event)
    }

    // MARK: - Deferred completion

    private func deferCompletion(_ filePath: String, data: GeminiSession, projectDir: String,
                                 mtime: TimeInterval, msgCount: Int) {
        cancelPending(filePath)

        let sessionId = "gemini:" + (data.sessionId ?? fileBaseName(filePath))
        let cwd = cwdMap?[projectDir] ?? ""

        if let existing = tracked[filePath],
           existing.lastState == "attention",
           existing.msgCount == msgCount,
           !existing.hasTools {
            tracked[filePath]?.mtime = mtime
            tracked[filePath]?.lastEventTime = Date()
            return
        }

        if tracked[filePath] != nil {
            tracked[filePath]?.mtime = mtime
            tracked[filePath]?.lastEventTime = Date()
        } else {
            tracked[filePath] = TrackedFile(
                mtime: mtime, sessionId: sessionId, lastState: nil,
                lastEventTime: Date(), msgCount: msgCount, hasTools: false,
                cwd: cwd, turnHasTools: false
            )
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.pendingCompletions[filePath] != nil else { return }
            self.pendingCompletions.removeValue(forKey: filePath)
            self.tracked[filePath] = TrackedFile(
                mtime: mtime, sessionId: sessionId, lastState: "attention",
                lastEventTime: Date(), msgCount: msgCount, hasTools: false,
                cwd: cwd, turnHasTools: false
            )
            logger.info("deferred state=attention session=\(sessionId)")
            self.onStateChange?(sessionId, "attention", "Stop")
        }

        pendingCompletions[filePath] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + deferCompletionDelay, execute: workItem)
    }

    private func cancelPending(_ filePath: String) {
        if let item = pendingCompletions.removeValue(forKey: filePath) {
            item.cancel()
        }
    }

    // MARK: - Stale cleanup

    private func cleanStale() {
        let now = Date()
        for (filePath, file) in tracked {
            if now.timeIntervalSince(file.lastEventTime) > staleThreshold {
                cancelPending(filePath)
                logger.info("stale session=\(file.sessionId)")
                onStateChange?(file.sessionId, "sleeping", "SessionEnd")
                tracked.removeValue(forKey: filePath)
            }
        }
    }

    // MARK: - Helpers

    private func fileBaseName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        if name.hasSuffix(".json") {
            return String(name.dropLast(5))
        }
        return name
    }
}
