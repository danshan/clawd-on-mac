import Foundation
import Network
import os
import AppKit

struct RuntimeConfig {
    static func write(port: Int) throws {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let clawdDir = homeDir.appendingPathComponent(".clawd")

        try FileManager.default.createDirectory(at: clawdDir, withIntermediateDirectories: true)

        let runtimeFile = clawdDir.appendingPathComponent("runtime.json")
        let data = try JSONEncoder().encode(["port": port])
        try data.write(to: runtimeFile, options: .atomic)
    }

    static func cleanup() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let runtimeFile = homeDir.appendingPathComponent(".clawd/runtime.json")
        try? FileManager.default.removeItem(at: runtimeFile)
    }

    static func readPort() -> Int? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let runtimeFile = homeDir.appendingPathComponent(".clawd/runtime.json")

        guard let data = try? Data(contentsOf: runtimeFile),
              let json = try? JSONDecoder().decode([String: Int].self, from: data),
              let port = json["port"] else {
            return nil
        }

        return port
    }
}

private let logger = Logger(subsystem: "com.clawd.onmac", category: "HTTPServer")

class HTTPServer {
    private let stateActor: PetStateActor
    private let themeLoader: ThemeLoader
    private var listener: NWListener?
    private var serverPort: Int = 23333
    private let PORT_RANGE = 23333...23337

    // Cache for expensive ToolScanner results
    private var toolsCache: (data: Data, timestamp: Date)?
    private let toolsCacheTTL: TimeInterval = 300 // 5 minutes

    var activePort: Int? { listener != nil ? serverPort : nil }

    init(stateActor: PetStateActor, themeLoader: ThemeLoader) {
        self.stateActor = stateActor
        self.themeLoader = themeLoader
    }

    func start() {
        for candidatePort in PORT_RANGE {
            do {
                let parameters = NWParameters.tcp
                guard let port = NWEndpoint.Port(rawValue: UInt16(candidatePort)) else {
                    logger.warning("Invalid port \(candidatePort, privacy: .public)")
                    continue
                }
                listener = try NWListener(using: parameters, on: port)
                serverPort = candidatePort
                break
            } catch {
                logger.debug("Port \(candidatePort, privacy: .public) unavailable: \(error.localizedDescription, privacy: .public)")
                continue
            }
        }

        guard let listener = listener else {
            logger.error("All ports 23333-23337 are in use")
            return
        }

        do {
            try RuntimeConfig.write(port: serverPort)
        } catch {
            logger.warning("Failed to write runtime config: \(error.localizedDescription, privacy: .public)")
        }

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                logger.info("HTTP server listening on port \(self?.serverPort ?? 0, privacy: .public)")
            case .failed(let error):
                logger.error("Server failed: \(error, privacy: .public)")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener.start(queue: .global())
    }

    private func handleConnection(_ connection: NWConnection) {
        // Reject non-loopback connections
        if let remote = connection.currentPath?.remoteEndpoint,
           case let .hostPort(host, _) = remote {
            let hostStr = "\(host)"
            if hostStr != "127.0.0.1" && hostStr != "::1" && hostStr != "localhost" {
                connection.cancel()
                return
            }
        }

        connection.start(queue: .global())

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data else { return }

            if let request = String(data: data, encoding: .utf8) {
                self.processRequest(request, connection: connection)
            }

            if isComplete {
                connection.cancel()
            }
        }
    }

    private func processRequest(_ request: String, connection: NWConnection) {
        let lines = request.split(separator: "\r\n")
        guard let requestLine = lines.first else { return }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return }

        let method = String(parts[0])
        let path = String(parts[1])

        if method == "GET" && path == "/state" {
            let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"status\":\"ok\",\"version\":\"1.0.0\"}"
            sendResponse(response, connection: connection)
            return
        }

        if method == "POST" && path == "/state" {
            if let bodyRange = request.range(of: "\r\n\r\n") {
                let bodyStart = bodyRange.upperBound
                let body = String(request[bodyStart...])
                handleStateUpdate(body, connection: connection)
            }
            return
        }

        if method == "GET" && path.hasPrefix("/icons/") && path.hasSuffix(".png") {
            let idStart = path.index(path.startIndex, offsetBy: 7)
            let idEnd = path.index(path.endIndex, offsetBy: -4)
            let toolId = String(path[idStart..<idEnd])
            // Check custom icons dir first, then built-in
            let customIconPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".clawd/icons/\(toolId).png")
            let pngData: Data?
            if FileManager.default.fileExists(atPath: customIconPath.path) {
                pngData = try? Data(contentsOf: customIconPath)
            } else {
                pngData = ToolIcons.pngData(for: toolId)
            }
            if let pngData = pngData {
                let headers = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nCache-Control: public, max-age=86400\r\nContent-Length: \(pngData.count)\r\n\r\n"
                sendBinaryResponse(headers: headers, body: pngData, connection: connection)
            } else {
                let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
                sendResponse(response, connection: connection)
            }
            return
        }

        if method == "GET" && path == "/api/tools" {
            // Use cached result if fresh enough
            if let cached = toolsCache, Date().timeIntervalSince(cached.timestamp) < toolsCacheTTL {
                if let jsonString = String(data: cached.data, encoding: .utf8) {
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(cached.data.count)\r\n\r\n\(jsonString)"
                    sendResponse(response, connection: connection)
                } else {
                    toolsCache = nil // Invalidate corrupted cache
                }
                return
            }
            // Scan in background to avoid blocking
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let tools = ToolScanner.scan()
                if let jsonData = try? JSONEncoder().encode(tools),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    self?.toolsCache = (data: jsonData, timestamp: Date())
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(jsonData.count)\r\n\r\n\(jsonString)"
                    self?.sendResponse(response, connection: connection)
                } else {
                    let response = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n"
                    self?.sendResponse(response, connection: connection)
                }
            }
            return
        }

        if method == "POST" && path == "/api/tools/refresh" {
            // Force refresh cache
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let tools = ToolScanner.scan()
                if let jsonData = try? JSONEncoder().encode(tools),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    self?.toolsCache = (data: jsonData, timestamp: Date())
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(jsonData.count)\r\n\r\n\(jsonString)"
                    self?.sendResponse(response, connection: connection)
                } else {
                    let response = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n"
                    self?.sendResponse(response, connection: connection)
                }
            }
            return
        }

        if method == "POST" && path == "/api/pick-folder" {
            DispatchQueue.main.async { [weak self] in
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.prompt = "Select"
                panel.message = "Choose a folder"
                let result = panel.runModal()
                if result == .OK, let url = panel.url {
                    self?.sendJSON(["path": url.path], connection: connection)
                } else {
                    self?.sendJSON(["cancelled": "true"], connection: connection)
                }
            }
            return
        }

        if method == "GET" && path == "/dashboard" {
            let html = DashboardHTML.page
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\n\r\n\(html)"
            sendResponse(response, connection: connection)
            return
        }

        if method == "POST" && path == "/permission" {
            if let bodyRange = request.range(of: "\r\n\r\n") {
                let bodyStart = bodyRange.upperBound
                let body = String(request[bodyStart...])
                handlePermissionRequest(body, connection: connection)
            }
            return
        }

        if method == "GET" && path == "/api/settings" {
            if let settings = getSettings?(),
               let jsonData = try? JSONSerialization.data(withJSONObject: settings),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(jsonData.count)\r\n\r\n\(jsonString)"
                sendResponse(response, connection: connection)
            } else {
                let response = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n"
                sendResponse(response, connection: connection)
            }
            return
        }

        if method == "POST" && path == "/api/settings" {
            if let bodyRange = request.range(of: "\r\n\r\n") {
                let bodyStart = bodyRange.upperBound
                let body = String(request[bodyStart...])
                handleSettingsUpdate(body, connection: connection)
            }
            return
        }

        // ── Icon Upload API ──
        if method == "POST" && path == "/api/icons/upload" {
            if let bodyRange = request.range(of: "\r\n\r\n") {
                let body = String(request[bodyRange.upperBound...])
                handleIconUpload(body: body, connection: connection)
            }
            return
        }

        // ── Skills API ──
        if path.hasPrefix("/api/skills") {
            handleSkillsAPI(method: method, path: path, request: request, connection: connection)
            return
        }

        let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
        sendResponse(response, connection: connection)
    }

    private func handleStateUpdate(_ body: String, connection: NWConnection) {
        guard let data = body.data(using: .utf8) else { return }

        struct StateUpdate: Codable {
            let state: String
            let session_id: String?
            let event: String?
            let source_pid: Int32?
            let cwd: String?
            let agent_id: String?
            let display_hint: String?
        }

        guard let update = try? JSONDecoder().decode(StateUpdate.self, from: data) else {
            let response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"
            sendResponse(response, connection: connection)
            return
        }

        // Gate: skip if agent is disabled
        let agentId = update.agent_id ?? "claude-code"
        if isAgentEnabled?(agentId) == false {
            let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
            sendResponse(response, connection: connection)
            return
        }

        Task {
            await stateActor.updateSession(
                update.session_id ?? "default",
                state: update.state,
                event: update.event,
                sourcePid: update.source_pid,
                cwd: update.cwd,
                agentId: agentId,
                displayHint: update.display_hint
            )
        }

        let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
        sendResponse(response, connection: connection)
    }

    var bubbleManager: BubbleManager?
    var getPetFrame: (() -> NSRect)?
    var isAgentEnabled: ((String) -> Bool)?
    var isAgentPermissionsEnabled: ((String) -> Bool)?
    var isDND: (() -> Bool)?
    var isHideBubbles: (() -> Bool)?
    var getSettings: (() -> [String: Any])?
    var updateSetting: ((String, Any) -> String)?
    var skillsManager: SkillsManager?

    private func handleSettingsUpdate(_ body: String, connection: NWConnection) {
        guard let data = body.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let response = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n\r\n{\"error\":\"Invalid JSON\"}"
            sendResponse(response, connection: connection)
            return
        }

        var results: [String: String] = [:]
        for (key, value) in dict {
            let result = updateSetting?(key, value) ?? "error"
            results[key] = result
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: results),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(jsonData.count)\r\n\r\n\(jsonString)"
            sendResponse(response, connection: connection)
        } else {
            let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"status\":\"ok\"}"
            sendResponse(response, connection: connection)
        }
    }

    private func handleIconUpload(body: String, connection: NWConnection) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = json["key"] as? String, !key.isEmpty,
              let base64 = json["icon"] as? String, !base64.isEmpty,
              let pngData = Data(base64Encoded: base64) else {
            sendJSON(["error": "Missing key or icon (base64 PNG)"], status: 400, connection: connection)
            return
        }
        do {
            // Normalize key: store with both underscore and hyphen variants
            let hyphenKey = key.replacingOccurrences(of: "_", with: "-")
            let iconsDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".clawd/icons")
            try FileManager.default.createDirectory(at: iconsDir, withIntermediateDirectories: true)
            let iconPath = iconsDir.appendingPathComponent("\(hyphenKey).png")
            try pngData.write(to: iconPath)
            sendJSON(["status": "ok"], connection: connection)
        } catch {
            sendError(error, connection: connection)
        }
    }

    private func handlePermissionRequest(_ body: String, connection: NWConnection) {
        guard let data = body.data(using: .utf8) else { return }

        struct PermissionRequest: Codable {
            let tool_name: String
            let session_id: String?
            let permission_suggestions: [[String: String]]?
            let agent_id: String?
            let is_elicitation: Bool?
            let bridge_url: String?
            let bridge_token: String?
            let request_id: String?
        }

        guard let request = try? JSONDecoder().decode(PermissionRequest.self, from: data) else {
            let response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"
            sendResponse(response, connection: connection)
            return
        }

        // Parse raw JSON for tool_input and suggestions (may contain nested objects)
        let toolInput: [String: Any]?
        var rawSuggestions: [[String: Any]] = []
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            toolInput = json["tool_input"] as? [String: Any]
            if let suggestions = json["permission_suggestions"] as? [[String: Any]] {
                rawSuggestions = suggestions
            }
        } else {
            toolInput = nil
        }

        // Merge multiple addRules suggestions into one button (e.g. piped commands)
        let addRulesItems = rawSuggestions.filter { ($0["type"] as? String) == "addRules" }
        let mergedRawSuggestions: [[String: Any]]
        if addRulesItems.count > 1 {
            let nonAddRules = rawSuggestions.filter { ($0["type"] as? String) != "addRules" }
            let mergedRules = addRulesItems.flatMap { item -> [[String: Any]] in
                if let rules = item["rules"] as? [[String: Any]] {
                    return rules
                }
                var rule: [String: Any] = [:]
                if let t = item["toolName"] { rule["toolName"] = t }
                if let r = item["ruleContent"] { rule["ruleContent"] = r }
                return rule.isEmpty ? [] : [rule]
            }
            var merged: [String: Any] = [
                "type": "addRules",
                "destination": addRulesItems[0]["destination"] ?? "localSettings",
                "behavior": addRulesItems[0]["behavior"] ?? "allow",
                "rules": mergedRules,
            ]
            mergedRawSuggestions = nonAddRules + [merged]
        } else {
            mergedRawSuggestions = rawSuggestions
        }

        // Convert raw suggestions to [String: String] for display (label/behavior)
        let displaySuggestions: [[String: String]] = mergedRawSuggestions.map { dict in
            var result: [String: String] = [:]
            for (k, v) in dict { result[k] = "\(v)" }
            return result
        }

        // ── Opencode fire-and-forget branch ──
        // Plugin sends fire-and-forget POST. We 200-ACK immediately,
        // then send the decision back via reverse HTTP bridge.
        let isOpencode = request.agent_id == "opencode"
        if isOpencode {
            let ack = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
            sendResponse(ack, connection: connection)

            let bridgeUrl = request.bridge_url ?? ""
            let bridgeToken = request.bridge_token ?? ""
            let requestId = request.request_id ?? ""

            // Agent disabled → silent drop, TUI fallback
            if isAgentEnabled?("opencode") == false {
                return
            }

            guard !requestId.isEmpty, !bridgeUrl.isEmpty, !bridgeToken.isEmpty else {
                return
            }

            // DND / hideBubbles → silent drop, TUI fallback
            if isDND?() == true || isHideBubbles?() == true {
                return
            }
            if isAgentPermissionsEnabled?("opencode") == false {
                return
            }

            let entry = PermissionEntry(
                sessionId: request.session_id ?? "default",
                toolName: request.tool_name,
                toolInput: toolInput,
                suggestions: displaySuggestions,
                rawSuggestions: mergedRawSuggestions,
                agentId: "opencode",
                isElicitation: request.is_elicitation ?? false,
                createdAt: Date()
            )
            let petFrame = getPetFrame?() ?? NSRect(x: 100, y: 100, width: 150, height: 100)

            DispatchQueue.main.async { [weak self] in
                let timeoutItem = DispatchWorkItem {
                    self?.replyOpencodePermission(
                        bridgeUrl: bridgeUrl, bridgeToken: bridgeToken,
                        requestId: requestId, reply: "reject", toolName: request.tool_name
                    )
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeoutItem)

                self?.bubbleManager?.showPermission(entry, petFrame: petFrame) { [weak self] action in
                    timeoutItem.cancel()
                    let reply: String
                    if action == "deny" {
                        reply = "reject"
                    } else {
                        reply = "once"
                    }
                    self?.replyOpencodePermission(
                        bridgeUrl: bridgeUrl, bridgeToken: bridgeToken,
                        requestId: requestId, reply: reply, toolName: request.tool_name
                    )
                }
            }
            return
        }

        // ── Standard (connection-held) branch ──

        // Gate: DND — destroy connection so agent falls back to terminal prompt
        if isDND?() == true {
            connection.cancel()
            return
        }

        // Gate: auto-deny if agent permissions are disabled
        // ExitPlanMode and AskUserQuestion are UX flows, not approvals — always show them
        let permAgentId = request.agent_id ?? "claude-code"
        let toolName = request.tool_name
        let isUXFlow = toolName == "ExitPlanMode" || toolName == "AskUserQuestion"
        if !isUXFlow && isAgentPermissionsEnabled?(permAgentId) == false {
            // Destroy connection without responding — agent falls back to terminal prompt
            connection.cancel()
            return
        }

        // Gate: hideBubbles — same as DND, but only for non-UX flows
        if !isUXFlow && isHideBubbles?() == true {
            connection.cancel()
            return
        }

        // Passthrough: metadata-only tools auto-allowed without bubble
        let passthroughTools: Set<String> = [
            "TaskCreate", "TaskUpdate", "TaskGet", "TaskList", "TaskStop", "TaskOutput",
        ]
        if passthroughTools.contains(toolName) {
            let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"behavior\":\"allow\"}"
            sendResponse(response, connection: connection)
            return
        }

        let entry = PermissionEntry(
            sessionId: request.session_id ?? "default",
            toolName: request.tool_name,
            toolInput: toolInput,
            suggestions: displaySuggestions,
            rawSuggestions: mergedRawSuggestions,
            agentId: request.agent_id ?? "claude-code",
            isElicitation: request.is_elicitation ?? false,
            createdAt: Date()
        )

        let petFrame = getPetFrame?() ?? NSRect(x: 100, y: 100, width: 150, height: 100)

        DispatchQueue.main.async { [weak self] in
            // Timeout permission requests after 600s to prevent connection leak
            let timeoutItem = DispatchWorkItem {
                let timeoutBody = "{\"action\":\"deny\"}"
                let timeoutResponse = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(timeoutBody.count)\r\n\r\n\(timeoutBody)"
                self?.sendResponse(timeoutResponse, connection: connection)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: timeoutItem)

            self?.bubbleManager?.showPermission(entry, petFrame: petFrame) { [weak self] action in
                timeoutItem.cancel()
                let responseBody: String
                if action.hasPrefix("elicitation-submit:") {
                    let jsonStr = String(action.dropFirst("elicitation-submit:".count))
                    if let jsonData = jsonStr.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                       let answers = parsed["answers"] as? [String: String] {
                        let updatedInput = self?.buildElicitationUpdatedInput(
                            toolInput: entry.toolInput, answers: answers
                        ) ?? [:]
                        if let respData = try? JSONSerialization.data(
                            withJSONObject: ["behavior": "allow", "updatedInput": updatedInput]
                        ), let respStr = String(data: respData, encoding: .utf8) {
                            responseBody = respStr
                        } else {
                            responseBody = "{\"behavior\":\"allow\"}"
                        }
                    } else {
                        responseBody = "{\"behavior\":\"deny\"}"
                    }
                } else if action.hasPrefix("suggestion:") {
                    let idxStr = String(action.dropFirst("suggestion:".count))
                    if let idx = Int(idxStr), idx >= 0, idx < entry.rawSuggestions.count {
                        let suggestion = entry.rawSuggestions[idx]
                        var decision: [String: Any] = ["behavior": "allow"]
                        var perm = suggestion
                        if perm["type"] == nil { perm["type"] = "addRules" }
                        decision["updatedPermissions"] = [perm]
                        if let respData = try? JSONSerialization.data(withJSONObject: decision),
                           let respStr = String(data: respData, encoding: .utf8) {
                            responseBody = respStr
                        } else {
                            responseBody = "{\"behavior\":\"allow\"}"
                        }
                    } else {
                        responseBody = "{\"behavior\":\"allow\"}"
                    }
                } else {
                    let escaped = self?.jsonEscape(action) ?? action
                    responseBody = "{\"behavior\":\"\(escaped)\"}"
                }
                let httpResponse = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(responseBody.count)\r\n\r\n\(responseBody)"
                self?.sendResponse(httpResponse, connection: connection)
            }
        }
    }

    private func jsonEscape(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            default:
                if ch.value < 0x20 {
                    result += String(format: "\\u%04x", ch.value)
                } else {
                    result += String(ch)
                }
            }
        }
        return result
    }

    private func buildElicitationUpdatedInput(toolInput: [String: Any]?, answers: [String: String]) -> [String: Any] {
        var input = toolInput ?? [:]
        let questions = input["questions"] as? [[String: Any]] ?? []
        var normalizedAnswers: [String: String] = [:]
        for question in questions {
            guard let qText = question["question"] as? String, !qText.isEmpty else { continue }
            if let answer = answers[qText], !answer.trimmingCharacters(in: .whitespaces).isEmpty {
                normalizedAnswers[qText] = answer.trimmingCharacters(in: .whitespaces)
            }
        }
        input["answers"] = normalizedAnswers
        return input
    }

    /// Reverse HTTP bridge for opencode: POST decision back to plugin's Hono server
    private func replyOpencodePermission(bridgeUrl: String, bridgeToken: String, requestId: String, reply: String, toolName: String) {
        guard !bridgeUrl.isEmpty, !bridgeToken.isEmpty, !requestId.isEmpty else { return }
        let fullUrl = bridgeUrl.hasSuffix("/") ? "\(bridgeUrl)reply" : "\(bridgeUrl)/reply"
        guard let url = URL(string: fullUrl) else { return }

        let body: [String: String] = ["request_id": requestId, "reply": reply]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = bodyData
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(bridgeToken)", forHTTPHeaderField: "Authorization")
        urlRequest.timeoutInterval = 5

        URLSession.shared.dataTask(with: urlRequest) { _, response, error in
            if let error = error {
                os.Logger(subsystem: "com.clawd.mac", category: "opencode")
                    .error("opencode bridge reply failed: \(error.localizedDescription)")
            }
        }.resume()
    }

    // MARK: - Skills API

    private func handleSkillsAPI(method: String, path: String, request: String, connection: NWConnection) {
        guard let sm = skillsManager else {
            sendJSON(["error": "Skills manager not initialized"], status: 503, connection: connection)
            return
        }

        let body: String? = request.range(of: "\r\n\r\n").map { String(request[$0.upperBound...]) }

        // Parse path: /api/skills, /api/skills/{id}, /api/skills/{id}/sync, etc.
        let pathWithoutQuery = path.components(separatedBy: "?").first ?? path
        let segments = pathWithoutQuery.split(separator: "/").map(String.init)
        // segments: ["api", "skills", ...]

        switch (method, segments.count) {

        // GET /api/skills — list all
        case ("GET", 2):
            do {
                let skills = try sm.listSkills()
                sendCodable(skills, connection: connection)
            } catch { sendError(error, connection: connection) }

        // GET /api/skills/tools — tool status
        case ("GET", 3) where segments[2] == "tools":
            do {
                let tools = try sm.getToolsStatus()
                sendCodable(tools, connection: connection)
            } catch { sendError(error, connection: connection) }

        // GET /api/skills/discover — discover unmanaged
        case ("GET", 3) where segments[2] == "discover":
            do {
                let discovered = try sm.discoverSkills()
                sendCodable(discovered, connection: connection)
            } catch { sendError(error, connection: connection) }

        // GET /api/skills/preview-path?path=... — preview skill content at path
        case ("GET", 3) where segments[2].hasPrefix("preview-path"):
            let skillPath = extractQueryParam(path: path, param: "path") ?? ""
            guard !skillPath.isEmpty else {
                sendJSON(["error": "Missing path parameter"], status: 400, connection: connection)
                return
            }
            let skillURL = URL(fileURLWithPath: skillPath)
            // Try SKILL.md, then README.md, then first .md file
            let candidates = ["SKILL.md", "README.md"]
            var content: String? = nil
            for name in candidates {
                let filePath = skillURL.appendingPathComponent(name).path
                if FileManager.default.fileExists(atPath: filePath),
                   let text = try? String(contentsOfFile: filePath, encoding: .utf8) {
                    content = String(text.prefix(3000))
                    break
                }
            }
            if content == nil {
                // Try first .md file
                if let items = try? FileManager.default.contentsOfDirectory(atPath: skillPath) {
                    for item in items where item.hasSuffix(".md") {
                        let filePath = skillURL.appendingPathComponent(item).path
                        if let text = try? String(contentsOfFile: filePath, encoding: .utf8) {
                            content = String(text.prefix(3000))
                            break
                        }
                    }
                }
            }
            if let content = content {
                sendJSON(["content": content], connection: connection)
            } else {
                sendJSON(["content": ""], connection: connection)
            }

        // GET /api/skills/marketplace — leaderboard
        case ("GET", 3) where segments[2] == "marketplace":
            Task {
                do {
                    let skills = try await sm.fetchMarketplace()
                    sendCodable(skills, connection: connection)
                } catch { sendError(error, connection: connection) }
            }

        // GET /api/skills/marketplace/search?q=...
        case ("GET", 4) where segments[2] == "marketplace" && segments[3].hasPrefix("search"):
            let query = extractQueryParam(path: path, param: "q") ?? ""
            let limit = Int(extractQueryParam(path: path, param: "limit") ?? "20") ?? 20
            Task {
                do {
                    let results = try await sm.searchMarketplace(query: query, limit: limit)
                    sendCodable(results, connection: connection)
                } catch { sendError(error, connection: connection) }
            }

        // GET /api/skills/marketplace/repos — list custom repos
        case ("GET", 4) where segments[2] == "marketplace" && segments[3].hasPrefix("repos") && !segments[3].contains("scan"):
            do {
                let repos = try sm.getMarketplaceRepos()
                let data = try JSONSerialization.data(withJSONObject: repos)
                let json = String(data: data, encoding: .utf8) ?? "[]"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(data.count)\r\n\r\n\(json)"
                sendResponse(response, connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/marketplace/repos — add custom repo
        case ("POST", 4) where segments[2] == "marketplace" && segments[3] == "repos":
            guard let body = body, let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let url = json["url"] as? String else {
                sendJSON(["error": "Missing url"], status: 400, connection: connection)
                return
            }
            do {
                let entry = try sm.addMarketplaceRepo(url: url, name: json["name"] as? String)
                let respData = try JSONSerialization.data(withJSONObject: entry)
                let respJson = String(data: respData, encoding: .utf8) ?? "{}"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(respData.count)\r\n\r\n\(respJson)"
                sendResponse(response, connection: connection)
            } catch { sendError(error, connection: connection) }

        // DELETE /api/skills/marketplace/repos — remove custom repo
        case ("DELETE", 4) where segments[2] == "marketplace" && segments[3] == "repos":
            guard let body = body, let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let url = json["url"] as? String else {
                sendJSON(["error": "Missing url"], status: 400, connection: connection)
                return
            }
            do {
                try sm.removeMarketplaceRepo(url: url)
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // GET /api/skills/marketplace/repos/scan?url=...
        case ("GET", 5) where segments[2] == "marketplace" && segments[3] == "repos" && segments[4].hasPrefix("scan"):
            let repoUrl = extractQueryParam(path: path, param: "url") ?? ""
            guard !repoUrl.isEmpty else {
                sendJSON(["error": "Missing url parameter"], status: 400, connection: connection)
                return
            }
            Task {
                do {
                    let skills = try await sm.scanMarketplaceRepo(url: repoUrl)
                    sendCodable(skills, connection: connection)
                } catch { sendError(error, connection: connection) }
            }

        // POST /api/skills/marketplace/repos/install — install skill from repo
        case ("POST", 5) where segments[2] == "marketplace" && segments[3] == "repos" && segments[4] == "install":
            guard let body = body, let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let repoUrl = json["repo_url"] as? String,
                  let skillPath = json["skill_path"] as? String else {
                sendJSON(["error": "Missing repo_url or skill_path"], status: 400, connection: connection)
                return
            }
            let subpath = skillPath == "." ? nil : skillPath
            Task {
                do {
                    let skill = try await sm.installFromGit(url: repoUrl, branch: nil, subpath: subpath, name: json["name"] as? String, sourceType: "git")
                    sendCodable(skill, connection: connection)
                } catch { sendError(error, connection: connection) }
            }

        // POST /api/skills/install — install skill
        case ("POST", 3) where segments[2] == "install":
            guard let body = body, let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                sendJSON(["error": "Invalid JSON"], status: 400, connection: connection)
                return
            }
            let source = json["source"] as? String ?? ""
            let name = json["name"] as? String
            let sourceType = json["source_type"] as? String ?? "local"

            if sourceType == "git" || sourceType == "skillssh" {
                let branch = json["branch"] as? String
                let subpath = json["subpath"] as? String
                Task {
                    do {
                        let skill = try await sm.installFromGit(url: source, branch: branch, subpath: subpath, name: name, sourceType: sourceType)
                        sendCodable(skill, connection: connection)
                    } catch { sendError(error, connection: connection) }
                }
            } else {
                do {
                    let skill = try sm.installFromLocal(path: source, name: name)
                    sendCodable(skill, connection: connection)
                } catch { sendError(error, connection: connection) }
            }

        // POST /api/skills/import — import discovered
        case ("POST", 3) where segments[2] == "import":
            guard let body = body, let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let discoveredId = json["discovered_id"] as? String else {
                sendJSON(["error": "Missing discovered_id"], status: 400, connection: connection)
                return
            }
            do {
                let skill = try sm.importDiscovered(discoveredId: discoveredId, name: json["name"] as? String)
                sendCodable(skill, connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/install-marketplace — install from skills.sh
        case ("POST", 3) where segments[2] == "install-marketplace":
            guard let body = body, let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let source = json["source"] as? String else {
                sendJSON(["error": "Missing source URL"], status: 400, connection: connection)
                return
            }
            let name = json["name"] as? String
            let skillId = json["skill_id"] as? String
            Task {
                do {
                    let skill = try await sm.installFromMarketplace(source: source, skillId: skillId, name: name)
                    sendCodable(skill, connection: connection)
                } catch { sendError(error, connection: connection) }
            }

        // DELETE /api/skills/{id} — uninstall
        case ("DELETE", 3):
            let skillId = segments[2]
            do {
                try sm.uninstallSkill(id: skillId)
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/{id}/sync — sync to tool
        case ("POST", 4) where segments[3] == "sync":
            let skillId = segments[2]
            guard let body = body, let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tool = json["tool"] as? String else {
                sendJSON(["error": "Missing tool"], status: 400, connection: connection)
                return
            }
            do {
                try sm.syncToTool(skillId: skillId, toolKey: tool)
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/{id}/sync-all — sync to all tools
        case ("POST", 4) where segments[3] == "sync-all":
            let skillId = segments[2]
            do {
                try sm.syncToAllTools(skillId: skillId)
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // DELETE /api/skills/{id}/sync/{tool} — unsync
        case ("DELETE", 5) where segments[3] == "sync":
            let skillId = segments[2]
            let tool = segments[4]
            do {
                try sm.unsyncFromTool(skillId: skillId, toolKey: tool)
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/{id}/toggle-enabled — enable/disable skill
        case ("POST", 4) where segments[3] == "toggle-enabled":
            let skillId = segments[2]
            do {
                guard var skill = try sm.database.getSkill(id: skillId) else {
                    sendJSON(["error": "Skill not found"], status: 404, connection: connection)
                    return
                }
                let newEnabled = !skill.enabled
                try sm.database.updateSkillEnabled(id: skillId, enabled: newEnabled)

                // If disabling, unsync from all tools
                if !newEnabled {
                    let targets = try sm.database.getTargets(forSkill: skillId)
                    for target in targets {
                        try sm.unsyncFromTool(skillId: skillId, toolKey: target.tool)
                    }
                }

                let skills = try sm.listSkills()
                if let updated = skills.first(where: { $0.id == skillId }) {
                    sendCodable(updated, connection: connection)
                } else {
                    sendJSON(["status": "ok"], connection: connection)
                }
            } catch { sendError(error, connection: connection) }

        // GET /api/skills/{id}/document — skill markdown
        case ("GET", 4) where segments[3] == "document":
            let skillId = segments[2]
            do {
                if let content = try sm.getSkillDocument(id: skillId) {
                    sendJSON(["content": content], connection: connection)
                } else {
                    sendJSON(["error": "Not found"], status: 404, connection: connection)
                }
            } catch { sendError(error, connection: connection) }

        // GET /api/skills/{id}/files — list all files in skill directory
        case ("GET", 4) where segments[3] == "files":
            let skillId = segments[2]
            do {
                guard let skill = try sm.database.getSkill(id: skillId) else {
                    sendJSON(["error": "Not found"], status: 404, connection: connection)
                    return
                }
                let baseURL = URL(fileURLWithPath: skill.centralPath)
                let fm = FileManager.default
                var files: [[String: Any]] = []
                if let enumerator = fm.enumerator(at: baseURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
                    while let fileURL = enumerator.nextObject() as? URL {
                        let relativePath = fileURL.path.replacingOccurrences(of: baseURL.path + "/", with: "")
                        let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                        files.append(["path": relativePath, "isDir": isDir, "size": size])
                    }
                }
                let responseDict: [String: Any] = ["files": files, "basePath": skill.centralPath]
                let jsonData = try JSONSerialization.data(withJSONObject: responseDict)
                let jsonStr = String(data: jsonData, encoding: .utf8) ?? "[]"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: \(jsonStr.utf8.count)\r\n\r\n\(jsonStr)"
                connection.send(content: response.data(using: .utf8), contentContext: .finalMessage, isComplete: true, completion: .idempotent)
            } catch { sendError(error, connection: connection) }

        // GET /api/skills/{id}/file?path=... — read a file from skill directory
        case ("GET", 4) where segments[3] == "file":
            let skillId = segments[2]
            let relPath = extractQueryParam(path: path, param: "path") ?? "SKILL.md"
            do {
                guard let skill = try sm.database.getSkill(id: skillId) else {
                    sendJSON(["error": "Not found"], status: 404, connection: connection)
                    return
                }
                let baseURL = URL(fileURLWithPath: skill.centralPath)
                let fileURL = baseURL.appendingPathComponent(relPath)
                // Security: ensure file is within skill directory
                guard fileURL.standardizedFileURL.path.hasPrefix(baseURL.standardizedFileURL.path) else {
                    sendJSON(["error": "Access denied"], status: 403, connection: connection)
                    return
                }
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let content = try String(contentsOf: fileURL, encoding: .utf8)
                    sendJSON(["content": content, "path": relPath], connection: connection)
                } else {
                    sendJSON(["error": "File not found"], status: 404, connection: connection)
                }
            } catch { sendError(error, connection: connection) }

        // GET /api/skills/{id}/check-update — check single skill for updates
        case ("GET", 4) where segments[3] == "check-update":
            let skillId = segments[2]
            let force = extractQueryParam(path: path, param: "force") == "true"
            do {
                let dto = try sm.checkSkillUpdate(id: skillId, force: force)
                sendCodable(dto, connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/{id}/update — download and apply update
        case ("POST", 4) where segments[3] == "update":
            let skillId = segments[2]
            do {
                let result = try sm.updateSkill(id: skillId)
                sendCodable(result, connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/{id}/reimport — re-import local skill from source
        case ("POST", 4) where segments[3] == "reimport":
            let skillId = segments[2]
            do {
                let dto = try sm.reimportLocalSkill(id: skillId)
                sendCodable(dto, connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/{id}/relink — change source path
        case ("POST", 4) where segments[3] == "relink":
            let skillId = segments[2]
            guard let body = body, let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newPath = json["source_path"] as? String else {
                sendJSON(["error": "Missing source_path"], status: 400, connection: connection)
                return
            }
            do {
                let dto = try sm.relinkLocalSkillSource(id: skillId, newSourcePath: newPath)
                sendCodable(dto, connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/{id}/detach-source — forget source path
        case ("POST", 4) where segments[3] == "detach-source":
            let skillId = segments[2]
            do {
                let dto = try sm.detachLocalSkillSource(id: skillId)
                sendCodable(dto, connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/check-all-updates — check all skills
        case ("POST", 3) where segments[2] == "check-all-updates":
            let force = extractQueryParam(path: path, param: "force") == "true"
            do {
                let results = try sm.checkAllUpdates(force: force)
                sendCodable(results, connection: connection)
            } catch { sendError(error, connection: connection) }

        // GET /api/skills/tags — list all unique tags
        case ("GET", 3) where segments[2] == "tags":
            do {
                let tags = try sm.getAllTags()
                sendCodable(tags, connection: connection)
            } catch { sendError(error, connection: connection) }

        // GET /api/skills/by-tag?tag=xxx — list skills with specific tag
        case ("GET", 3) where segments[2] == "by-tag":
            guard let tag = extractQueryParam(path: path, param: "tag") else {
                sendJSON(["error": "Missing tag parameter"], status: 400, connection: connection)
                return
            }
            do {
                let skills = try sm.getSkillsByTag(tag: tag)
                sendCodable(skills, connection: connection)
            } catch { sendError(error, connection: connection) }

        // PUT /api/skills/{id}/tags — set skill tags
        case ("PUT", 4) where segments[3] == "tags":
            let skillId = segments[2]
            guard let body = body, let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tags = json["tags"] as? [String] else {
                sendJSON(["error": "Missing tags array"], status: 400, connection: connection)
                return
            }
            do {
                try sm.setSkillTags(id: skillId, tags: tags)
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/{id}/tags — add a tag
        case ("POST", 4) where segments[3] == "tags":
            let skillId = segments[2]
            guard let body = body, let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag"] as? String, !tag.isEmpty else {
                sendJSON(["error": "Missing tag"], status: 400, connection: connection)
                return
            }
            do {
                var existing = try sm.database.getTags(forSkill: skillId)
                if !existing.contains(tag) { existing.append(tag) }
                try sm.setSkillTags(id: skillId, tags: existing)
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // DELETE /api/skills/{id}/tags/{tag} — remove a tag
        case ("DELETE", 5) where segments[3] == "tags":
            let skillId = segments[2]
            let tag = segments[4].removingPercentEncoding ?? segments[4]
            do {
                var existing = try sm.database.getTags(forSkill: skillId)
                existing.removeAll { $0 == tag }
                try sm.setSkillTags(id: skillId, tags: existing)
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/batch-update — update multiple skills
        case ("POST", 3) where segments[2] == "batch-update":
            guard let body = body, let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ids = json["ids"] as? [String] else {
                sendJSON(["error": "Missing ids array"], status: 400, connection: connection)
                return
            }
            do {
                let result = try sm.batchUpdateSkills(ids: ids)
                sendCodable(result, connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/tools/{key}/enable — enable/disable a tool
        case ("POST", 4) where segments[2] == "tools":
            let toolKey = segments[3]
            guard let body = body, let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let enabled = json["enabled"] as? Bool else {
                sendJSON(["error": "Missing enabled field"], status: 400, connection: connection)
                return
            }
            do {
                try sm.setToolEnabled(key: toolKey, enabled: enabled)
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/tools-enable-all — bulk enable/disable
        case ("POST", 3) where segments[2] == "tools-enable-all":
            guard let body = body, let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let enabled = json["enabled"] as? Bool else {
                sendJSON(["error": "Missing enabled field"], status: 400, connection: connection)
                return
            }
            do {
                try sm.setAllToolsEnabled(enabled)
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/tools/{key}/path — override tool path
        case ("POST", 5) where segments[2] == "tools" && segments[4] == "path":
            let toolKey = segments[3]
            guard let body = body, let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let path = json["path"] as? String else {
                sendJSON(["error": "Missing path field"], status: 400, connection: connection)
                return
            }
            do {
                try sm.setCustomToolPath(key: toolKey, path: path)
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // DELETE /api/skills/tools/{key}/path — reset tool path
        case ("DELETE", 5) where segments[2] == "tools" && segments[4] == "path":
            let toolKey = segments[3]
            do {
                try sm.resetCustomToolPath(key: toolKey)
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/tools-custom — add custom tool
        case ("POST", 3) where segments[2] == "tools-custom":
            guard let body = body, let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let key = json["key"] as? String,
                  let displayName = json["display_name"] as? String,
                  let skillsDir = json["skills_dir"] as? String else {
                sendJSON(["error": "Missing key, display_name, or skills_dir"], status: 400, connection: connection)
                return
            }
            do {
                try sm.addCustomTool(key: key, displayName: displayName, skillsDir: skillsDir)
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // DELETE /api/skills/tools-custom/{key} — remove custom tool
        case ("DELETE", 4) where segments[2] == "tools-custom":
            let toolKey = segments[3]
            do {
                try sm.removeCustomTool(key: toolKey)
                // Also remove custom icon if exists
                let hyphenKey = toolKey.replacingOccurrences(of: "_", with: "-")
                let iconPath = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".clawd/icons/\(hyphenKey).png")
                try? FileManager.default.removeItem(at: iconPath)
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // ── Git Backup API ──

        // GET /api/skills/backup/status — get git backup status
        case ("GET", 4) where segments[2] == "backup" && segments[3] == "status":
            let status = sm.gitBackup.getStatus()
            sendCodable(status, connection: connection)

        // POST /api/skills/backup/init — initialize git repo
        case ("POST", 4) where segments[2] == "backup" && segments[3] == "init":
            do {
                try sm.gitBackup.initRepo()
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/backup/remote — set remote URL
        case ("POST", 4) where segments[2] == "backup" && segments[3] == "remote":
            guard let body = body,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let url = json["url"] as? String else {
                sendJSON(["error": "Missing url"], status: 400, connection: connection)
                return
            }
            do {
                try sm.gitBackup.setRemote(url: url)
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/backup/commit — commit all changes
        case ("POST", 4) where segments[2] == "backup" && segments[3] == "commit":
            guard let body = body,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = json["message"] as? String else {
                sendJSON(["error": "Missing message"], status: 400, connection: connection)
                return
            }
            do {
                try sm.gitBackup.commitAll(message: message)
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/backup/push — push to remote
        case ("POST", 4) where segments[2] == "backup" && segments[3] == "push":
            do {
                try sm.gitBackup.push()
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/backup/pull — pull from remote
        case ("POST", 4) where segments[2] == "backup" && segments[3] == "pull":
            do {
                try sm.gitBackup.pull()
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/backup/clone — clone from remote
        case ("POST", 4) where segments[2] == "backup" && segments[3] == "clone":
            guard let body = body,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let url = json["url"] as? String else {
                sendJSON(["error": "Missing url"], status: 400, connection: connection)
                return
            }
            do {
                try sm.gitBackup.cloneInto(url: url)
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/backup/snapshot — create snapshot tag
        case ("POST", 4) where segments[2] == "backup" && segments[3] == "snapshot":
            do {
                let tag = try sm.gitBackup.createSnapshot()
                sendJSON(["status": "ok", "tag": tag], connection: connection)
            } catch { sendError(error, connection: connection) }

        // GET /api/skills/backup/versions — list snapshot versions
        case ("GET", 4) where segments[2] == "backup" && segments[3] == "versions":
            do {
                let limit = Int(extractQueryParam(path: path, param: "limit") ?? "30") ?? 30
                let versions = try sm.gitBackup.listVersions(limit: limit)
                sendCodable(versions, connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/backup/restore — restore to snapshot
        case ("POST", 4) where segments[2] == "backup" && segments[3] == "restore":
            guard let body = body,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag"] as? String else {
                sendJSON(["error": "Missing tag"], status: 400, connection: connection)
                return
            }
            do {
                try sm.gitBackup.restoreVersion(tag: tag)
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // ── Scenarios API ──

        // GET /api/skills/scenarios — list all
        case ("GET", 3) where segments[2] == "scenarios":
            do {
                let scenarios = try sm.listScenarios()
                sendCodable(scenarios, connection: connection)
            } catch { sendError(error, connection: connection) }

        // GET /api/skills/scenarios/active — get active scenario
        case ("GET", 4) where segments[2] == "scenarios" && segments[3] == "active":
            do {
                let active = try sm.getActiveScenario()
                if let active = active {
                    sendCodable(active, connection: connection)
                } else {
                    sendJSON(["status": "none"], connection: connection)
                }
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/scenarios — create scenario
        case ("POST", 3) where segments[2] == "scenarios":
            guard let body = body,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = json["name"] as? String else {
                sendJSON(["error": "Missing name"], status: 400, connection: connection)
                return
            }
            do {
                let scenario = try sm.createScenario(
                    name: name,
                    description: json["description"] as? String,
                    icon: json["icon"] as? String
                )
                sendCodable(scenario, connection: connection)
            } catch { sendError(error, connection: connection) }

        // GET /api/skills/scenarios/{id} — get detail
        case ("GET", 4) where segments[2] == "scenarios":
            let sid = segments[3]
            do {
                let detail = try sm.getScenarioDetail(id: sid)
                sendCodable(detail, connection: connection)
            } catch { sendError(error, connection: connection) }

        // PUT /api/skills/scenarios/{id} — update scenario
        case ("PUT", 4) where segments[2] == "scenarios":
            let sid = segments[3]
            guard let body = body,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = json["name"] as? String else {
                sendJSON(["error": "Missing name"], status: 400, connection: connection)
                return
            }
            do {
                try sm.updateScenario(id: sid, name: name, description: json["description"] as? String, icon: json["icon"] as? String)
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // DELETE /api/skills/scenarios/{id} — delete scenario
        case ("DELETE", 4) where segments[2] == "scenarios":
            let sid = segments[3]
            do {
                try sm.deleteScenario(id: sid)
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/scenarios/{id}/activate — switch active
        case ("POST", 5) where segments[2] == "scenarios" && segments[4] == "activate":
            let sid = segments[3]
            do {
                try sm.switchScenario(id: sid)
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/scenarios/{id}/add-skill — add skill to scenario
        case ("POST", 5) where segments[2] == "scenarios" && segments[4] == "add-skill":
            let sid = segments[3]
            guard let body = body,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let skillId = json["skill_id"] as? String else {
                sendJSON(["error": "Missing skill_id"], status: 400, connection: connection)
                return
            }
            do {
                try sm.addSkillToScenario(scenarioId: sid, skillId: skillId)
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/scenarios/{id}/remove-skill — remove skill from scenario
        case ("POST", 5) where segments[2] == "scenarios" && segments[4] == "remove-skill":
            let sid = segments[3]
            guard let body = body,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let skillId = json["skill_id"] as? String else {
                sendJSON(["error": "Missing skill_id"], status: 400, connection: connection)
                return
            }
            do {
                try sm.removeSkillFromScenario(scenarioId: sid, skillId: skillId)
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/scenarios/reorder — reorder scenarios
        case ("POST", 4) where segments[2] == "scenarios" && segments[3] == "reorder":
            guard let body = body,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ids = json["ids"] as? [String] else {
                sendJSON(["error": "Missing ids array"], status: 400, connection: connection)
                return
            }
            do {
                try sm.reorderScenarios(ids: ids)
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/scenarios/{id}/reorder-skills — reorder skills within scenario
        case ("POST", 5) where segments[2] == "scenarios" && segments[4] == "reorder-skills":
            let sid = segments[3]
            guard let body = body,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let skillIds = json["skill_ids"] as? [String] else {
                sendJSON(["error": "Missing skill_ids array"], status: 400, connection: connection)
                return
            }
            do {
                try sm.reorderScenarioSkills(scenarioId: sid, skillIds: skillIds)
                sendJSON(["status": "ok"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // ──────────────────────────────────────────────
        // MARK: Projects API
        // ──────────────────────────────────────────────

        // GET /api/skills/projects — list all projects
        case ("GET", 3) where segments[2] == "projects":
            do {
                let projects = try sm.projectManager.listProjects()
                sendCodable(projects, connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/projects — add project
        case ("POST", 3) where segments[2] == "projects":
            do {
                let body = parseJSONBody(body)
                guard let path = body["path"] as? String else {
                    sendJSON(["error": "path required"], status: 400, connection: connection)
                    return
                }
                let project = try sm.projectManager.addProject(path: path)
                sendCodable(project, connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/projects/scan — scan for projects
        case ("POST", 4) where segments[2] == "projects" && segments[3] == "scan":
            do {
                let body = parseJSONBody(body)
                guard let root = body["root"] as? String else {
                    sendJSON(["error": "root required"], status: 400, connection: connection)
                    return
                }
                let maxDepth = (body["maxDepth"] as? Int) ?? 4
                let paths = try sm.projectManager.scanProjects(root: root, maxDepth: maxDepth)
                sendCodable(paths, connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/projects/reorder — reorder projects
        case ("POST", 4) where segments[2] == "projects" && segments[3] == "reorder":
            do {
                let body = parseJSONBody(body)
                guard let ids = body["ids"] as? [String] else {
                    sendJSON(["error": "ids array required"], status: 400, connection: connection)
                    return
                }
                try sm.projectManager.reorderProjects(ids: ids)
                sendJSON(["ok": "true"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // GET /api/skills/projects/{id} — get project detail
        case ("GET", 4) where segments[2] == "projects":
            do {
                let project = try sm.projectManager.getProject(id: segments[3])
                sendCodable(project, connection: connection)
            } catch { sendError(error, connection: connection) }

        // DELETE /api/skills/projects/{id} — remove project
        case ("DELETE", 4) where segments[2] == "projects":
            do {
                try sm.projectManager.removeProject(id: segments[3])
                sendJSON(["ok": "true"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // GET /api/skills/projects/{id}/agents — get agent targets
        case ("GET", 5) where segments[2] == "projects" && segments[4] == "agents":
            do {
                let agents = try sm.projectManager.getAgentTargets(projectId: segments[3])
                sendCodable(agents, connection: connection)
            } catch { sendError(error, connection: connection) }

        // GET /api/skills/projects/{id}/skills — get project skills
        case ("GET", 5) where segments[2] == "projects" && segments[4] == "skills":
            do {
                let agent = extractQueryParam(path: path, param: "agent")
                let skills = try sm.projectManager.getProjectSkills(projectId: segments[3], agent: agent)
                sendCodable(skills, connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/projects/{id}/toggle — toggle skill
        case ("POST", 5) where segments[2] == "projects" && segments[4] == "toggle":
            do {
                let body = parseJSONBody(body)
                guard let skillPath = body["skillPath"] as? String,
                      let agent = body["agent"] as? String,
                      let enabled = body["enabled"] as? Bool else {
                    sendJSON(["error": "skillPath, agent, enabled required"], status: 400, connection: connection)
                    return
                }
                try sm.projectManager.toggleProjectSkill(
                    projectId: segments[3], skillPath: skillPath, agent: agent, enabled: enabled)
                sendJSON(["ok": "true"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // DELETE /api/skills/projects/{id}/skills — delete project skill
        case ("DELETE", 5) where segments[2] == "projects" && segments[4] == "skills":
            do {
                let body = parseJSONBody(body)
                guard let skillPath = body["skillPath"] as? String,
                      let agent = body["agent"] as? String else {
                    sendJSON(["error": "skillPath and agent required"], status: 400, connection: connection)
                    return
                }
                try sm.projectManager.deleteProjectSkill(
                    projectId: segments[3], skillPath: skillPath, agent: agent)
                sendJSON(["ok": "true"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/projects/{id}/import — import project skill to center
        case ("POST", 5) where segments[2] == "projects" && segments[4] == "import":
            do {
                let body = parseJSONBody(body)
                guard let skillPath = body["skillPath"] as? String,
                      let agent = body["agent"] as? String else {
                    sendJSON(["error": "skillPath and agent required"], status: 400, connection: connection)
                    return
                }
                let newId = try sm.projectManager.importProjectSkillToCenter(
                    projectId: segments[3], skillPath: skillPath, agent: agent)
                sendJSON(["ok": "true", "skillId": newId], connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/projects/{id}/export — export center skill to project
        case ("POST", 5) where segments[2] == "projects" && segments[4] == "export":
            do {
                let body = parseJSONBody(body)
                guard let skillId = body["skillId"] as? String else {
                    sendJSON(["error": "skillId required"], status: 400, connection: connection)
                    return
                }
                let agents = body["agents"] as? [String]
                try sm.projectManager.exportSkillToProject(
                    skillId: skillId, projectId: segments[3], agents: agents)
                sendJSON(["ok": "true"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/projects/{id}/update-from-center — update project skill from center
        case ("POST", 5) where segments[2] == "projects" && segments[4] == "update-from-center":
            do {
                let body = parseJSONBody(body)
                guard let skillPath = body["skillPath"] as? String,
                      let centerSkillId = body["centerSkillId"] as? String else {
                    sendJSON(["error": "skillPath and centerSkillId required"], status: 400, connection: connection)
                    return
                }
                try sm.projectManager.updateProjectSkillFromCenter(
                    projectId: segments[3], skillPath: skillPath, centerSkillId: centerSkillId)
                sendJSON(["ok": "true"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/projects/{id}/update-to-center — push project skill to center
        case ("POST", 5) where segments[2] == "projects" && segments[4] == "update-to-center":
            do {
                let body = parseJSONBody(body)
                guard let skillPath = body["skillPath"] as? String,
                      let centerSkillId = body["centerSkillId"] as? String else {
                    sendJSON(["error": "skillPath and centerSkillId required"], status: 400, connection: connection)
                    return
                }
                try sm.projectManager.updateCenterSkillFromProject(
                    projectId: segments[3], skillPath: skillPath, centerSkillId: centerSkillId)
                sendJSON(["ok": "true"], connection: connection)
            } catch { sendError(error, connection: connection) }

        // GET /api/skills/projects/{id}/document — get project skill document
        case ("GET", 5) where segments[2] == "projects" && segments[4] == "document":
            do {
                guard let skillPath = extractQueryParam(path: path, param: "skillPath") else {
                    sendJSON(["error": "skillPath required"], status: 400, connection: connection)
                    return
                }
                let doc = try sm.projectManager.getProjectSkillDocument(
                    projectId: segments[3], skillPath: skillPath)
                sendJSON(["content": doc ?? ""], connection: connection)
            } catch { sendError(error, connection: connection) }

        // POST /api/skills/projects/{id}/diff — diff project skill vs center
        case ("POST", 5) where segments[2] == "projects" && segments[4] == "diff":
            do {
                let body = parseJSONBody(body)
                guard let skillPath = body["skillPath"] as? String,
                      let centerSkillId = body["centerSkillId"] as? String else {
                    sendJSON(["error": "skillPath and centerSkillId required"], status: 400, connection: connection)
                    return
                }
                let diff = try sm.projectManager.diffProjectSkill(
                    projectId: segments[3], skillPath: skillPath, centerSkillId: centerSkillId)
                sendCodable(diff, connection: connection)
            } catch { sendError(error, connection: connection) }

        default:
            sendJSON(["error": "Not found"], status: 404, connection: connection)
        }
    }

    private func sendCodable<T: Encodable>(_ value: T, connection: NWConnection) {
        do {
            let data = try JSONEncoder().encode(value)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(data.count)\r\n\r\n\(json)"
            sendResponse(response, connection: connection)
        } catch {
            sendError(error, connection: connection)
        }
    }

    private func sendJSON(_ dict: [String: String], status: Int = 200, connection: NWConnection) {
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8) {
            let statusText = status == 200 ? "OK" : (status == 400 ? "Bad Request" : (status == 404 ? "Not Found" : "Error"))
            let response = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(data.count)\r\n\r\n\(json)"
            sendResponse(response, connection: connection)
        }
    }

    private func sendError(_ error: Error, connection: NWConnection) {
        sendJSON(["error": error.localizedDescription], status: 500, connection: connection)
    }

    private func extractQueryParam(path: String, param: String) -> String? {
        guard let queryStart = path.firstIndex(of: "?") else { return nil }
        let query = String(path[path.index(after: queryStart)...])
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 && kv[0] == param {
                return String(kv[1]).removingPercentEncoding
            }
        }
        return nil
    }

    private func parseJSONBody(_ body: String?) -> [String: Any] {
        guard let body = body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private func sendResponse(_ response: String, connection: NWConnection) {
        guard let data = response.data(using: .utf8) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendBinaryResponse(headers: String, body: Data, connection: NWConnection) {
        guard var data = headers.data(using: .utf8) else { return }
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    func shutdown() {
        listener?.cancel()
        RuntimeConfig.cleanup()
    }
}