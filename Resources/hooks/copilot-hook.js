#!/usr/bin/env node
// Clawd — Copilot CLI hook (stdin JSON with camelCase fields)
// Registered in ~/.copilot/hooks/hooks.json by HookRegistrar
// preToolUse: gates tool execution via /permission bubble (blocking)

const { postStateToRunningServer, postPermissionToRunningServer } = require("./server-config");
const { createPidResolver, readStdinJson, getPlatformConfig } = require("./shared-process");

const EVENT_TO_STATE = {
  sessionStart: "idle",
  sessionEnd: "sleeping",
  userPromptSubmitted: "thinking",
  preToolUse: "working",
  postToolUse: "working",
  errorOccurred: "error",
  agentStop: "attention",
  subagentStart: "juggling",
  subagentStop: "working",
  preCompact: "sweeping",
};

const event = process.argv[2];
const state = EVENT_TO_STATE[event];
if (!state) process.exit(0);

const config = getPlatformConfig();
const resolve = createPidResolver({
  agentNames: { win: new Set(["copilot.exe"]), mac: new Set(["copilot"]) },
  agentCmdlineCheck: (cmd) => cmd.includes("@github/copilot"),
  platformConfig: config,
});

if (event === "sessionStart") resolve();

readStdinJson().then((payload) => {
  const sessionId = payload.sessionId || payload.session_id || "default";
  const cwd = payload.cwd || "";

  const { stablePid, agentPid, detectedEditor, pidChain } = resolve();

  const stateBody = { state, session_id: sessionId, event };
  stateBody.agent_id = "copilot-cli";
  if (cwd) stateBody.cwd = cwd;
  stateBody.source_pid = stablePid;
  if (detectedEditor) stateBody.editor = detectedEditor;
  if (agentPid) stateBody.agent_pid = agentPid;
  if (pidChain.length) stateBody.pid_chain = pidChain;

  // preToolUse: send state update (fire-and-forget) then block on permission bubble
  if (event === "preToolUse") {
    postStateToRunningServer(JSON.stringify(stateBody), { timeoutMs: 100 }, () => {});

    const toolName = payload.toolName || payload.tool_name || "Unknown";
    let toolInput = {};
    try {
      const raw = payload.toolArgs || payload.tool_args || payload.toolInput || payload.tool_input;
      toolInput = typeof raw === "string" ? JSON.parse(raw) : (raw || {});
    } catch {}

    const permBody = {
      tool_name: toolName,
      tool_input: toolInput,
      session_id: sessionId,
      agent_id: "copilot-cli",
    };

    postPermissionToRunningServer(JSON.stringify(permBody), {}, (err, data) => {
      if (err || !data) {
        // Clawd unavailable — allow by default (don't block the user)
        process.stdout.write(JSON.stringify({ permissionDecision: "allow" }) + "\n");
        process.exit(0);
        return;
      }

      // Parse Clawd's response — may be wrapped in hookSpecificOutput or flat
      let behavior = "allow";
      if (data.hookSpecificOutput && data.hookSpecificOutput.decision) {
        behavior = data.hookSpecificOutput.decision.behavior || "allow";
      } else if (data.behavior) {
        behavior = data.behavior;
      }

      if (behavior === "deny") {
        const reason = (data.hookSpecificOutput && data.hookSpecificOutput.decision && data.hookSpecificOutput.decision.message)
          || data.message || "Denied by Clawd";
        process.stdout.write(JSON.stringify({ permissionDecision: "deny", permissionDecisionReason: reason }) + "\n");
      } else {
        process.stdout.write(JSON.stringify({ permissionDecision: "allow" }) + "\n");
      }
      process.exit(0);
    });
    return;
  }

  // All other events: fire-and-forget state update
  postStateToRunningServer(
    JSON.stringify(stateBody),
    { timeoutMs: 100 },
    () => process.exit(0)
  );
});
