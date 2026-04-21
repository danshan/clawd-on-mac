import Foundation

// MARK: - Agent definition

struct AgentDefinition {
    let id: String
    let name: String
    let processNames: [String]  // macOS process names
    let eventSource: String     // "hook" or "process"
    let eventMap: [String: String]
    let capabilities: AgentCapabilities
    let systemSymbol: String    // SF Symbols name for menu icon

    struct AgentCapabilities {
        let httpHook: Bool
        let permissionApproval: Bool
        let sessionEnd: Bool
    }
}

// MARK: - Agent registry

class AgentRegistry {

    static let shared = AgentRegistry()

    let agents: [AgentDefinition] = [
        AgentDefinition(
            id: "claude-code",
            name: "Claude Code",
            processNames: ["claude"],
            eventSource: "hook",
            eventMap: [
                "SessionStart": "idle",
                "SessionEnd": "sleeping",
                "UserPromptSubmit": "thinking",
                "PreToolUse": "working",
                "PostToolUse": "working",
                "PostToolUseFailure": "error",
                "Stop": "attention",
                "StopFailure": "error",
                "SubagentStart": "juggling",
                "SubagentStop": "working",
                "PreCompact": "sweeping",
                "PostCompact": "attention",
                "Notification": "notification",
                "Elicitation": "notification",
                "WorktreeCreate": "carrying"
            ],
            capabilities: .init(httpHook: true, permissionApproval: true, sessionEnd: true),
            systemSymbol: "terminal"
        ),
        AgentDefinition(
            id: "codex",
            name: "Codex CLI",
            processNames: ["codex"],
            eventSource: "log-poll",
            eventMap: [
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
                "event_msg:turn_aborted": "idle"
            ],
            capabilities: .init(httpHook: false, permissionApproval: false, sessionEnd: false),
            systemSymbol: "chevron.left.forwardslash.chevron.right"
        ),
        AgentDefinition(
            id: "copilot-cli",
            name: "Copilot CLI",
            processNames: ["copilot"],
            eventSource: "hook",
            eventMap: [
                "sessionStart": "idle",
                "sessionEnd": "sleeping",
                "userPromptSubmitted": "thinking",
                "preToolUse": "working",
                "postToolUse": "working",
                "errorOccurred": "error",
                "agentStop": "attention",
                "subagentStart": "juggling",
                "subagentStop": "working",
                "preCompact": "sweeping"
            ],
            capabilities: .init(httpHook: false, permissionApproval: false, sessionEnd: true),
            systemSymbol: "airplane"
        ),
        AgentDefinition(
            id: "gemini-cli",
            name: "Gemini CLI",
            processNames: ["gemini"],
            eventSource: "log-poll",
            eventMap: [
                "SessionStart": "idle",
                "SessionEnd": "sleeping",
                "BeforeAgent": "thinking",
                "BeforeTool": "working",
                "AfterTool": "working",
                "AfterAgent": "attention",
                "Notification": "notification",
                "PreCompress": "sweeping"
            ],
            capabilities: .init(httpHook: false, permissionApproval: false, sessionEnd: true),
            systemSymbol: "diamond"
        ),
        AgentDefinition(
            id: "cursor-agent",
            name: "Cursor Agent",
            processNames: ["Cursor"],
            eventSource: "hook",
            eventMap: [
                "sessionStart": "idle",
                "sessionEnd": "sleeping",
                "beforeSubmitPrompt": "thinking",
                "preToolUse": "working",
                "postToolUse": "working",
                "postToolUseFailure": "working",
                "stop": "attention",
                "subagentStart": "juggling",
                "subagentStop": "working",
                "preCompact": "sweeping",
                "afterAgentThought": "thinking"
            ],
            capabilities: .init(httpHook: false, permissionApproval: false, sessionEnd: true),
            systemSymbol: "cursorarrow.click"
        ),
        AgentDefinition(
            id: "codebuddy",
            name: "CodeBuddy",
            processNames: ["CodeBuddy"],
            eventSource: "hook",
            eventMap: [
                "SessionStart": "idle",
                "SessionEnd": "sleeping",
                "UserPromptSubmit": "thinking",
                "PreToolUse": "working",
                "PostToolUse": "working",
                "Stop": "attention",
                "PermissionRequest": "notification",
                "Notification": "notification",
                "PreCompact": "sweeping"
            ],
            capabilities: .init(httpHook: true, permissionApproval: true, sessionEnd: true),
            systemSymbol: "person.2"
        ),
        AgentDefinition(
            id: "kiro-cli",
            name: "Kiro CLI",
            processNames: ["kiro"],
            eventSource: "hook",
            eventMap: [
                "agentSpawn": "idle",
                "userPromptSubmit": "thinking",
                "preToolUse": "working",
                "postToolUse": "working",
                "stop": "attention"
            ],
            capabilities: .init(httpHook: false, permissionApproval: false, sessionEnd: false),
            systemSymbol: "bolt"
        ),
        AgentDefinition(
            id: "opencode",
            name: "OpenCode",
            processNames: ["opencode"],
            eventSource: "plugin-event",
            eventMap: [
                "SessionStart": "idle",
                "SessionEnd": "sleeping",
                "UserPromptSubmit": "thinking",
                "PreToolUse": "working",
                "PostToolUse": "working",
                "PostToolUseFailure": "error",
                "Stop": "attention",
                "StopFailure": "error",
                "PreCompact": "sweeping",
                "PostCompact": "attention"
            ],
            capabilities: .init(httpHook: false, permissionApproval: true, sessionEnd: true),
            systemSymbol: "doc.text"
        ),
        AgentDefinition(
            id: "pi",
            name: "Pi",
            processNames: ["pi"],
            eventSource: "extension-event",
            eventMap: [
                "session_start": "idle",
                "session_shutdown": "sleeping",
                "input": "thinking",
                "tool_call": "working",
                "tool_result": "working",
                "agent_end": "attention",
                "tool_call_blocked": "error"
            ],
            capabilities: .init(httpHook: true, permissionApproval: true, sessionEnd: true),
            systemSymbol: "circle.fill"
        )
    ]

    private let agentMap: [String: AgentDefinition]

    private init() {
        agentMap = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
    }

    func getAgent(_ id: String) -> AgentDefinition? {
        return agentMap[id]
    }

    /// Check if agent is enabled in preferences.
    func isAgentEnabled(_ agentId: String, agents configs: [String: AgentConfig]?) -> Bool {
        guard let configs = configs else { return true }
        return configs[agentId]?.enabled ?? true
    }

    func isAgentPermissionsEnabled(_ agentId: String, agents configs: [String: AgentConfig]?) -> Bool {
        guard let configs = configs else { return true }
        return configs[agentId]?.permissionsEnabled ?? true
    }

    /// Map event name to pet state using the agent's event map.
    func mapEventToState(agentId: String, event: String) -> String? {
        guard let agent = agentMap[agentId] else { return nil }
        return agent.eventMap[event]
    }
}
