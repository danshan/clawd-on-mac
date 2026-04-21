#!/usr/bin/env node
// Clawd — Gemini CLI hook (stdin JSON with hook_event_name; stdout JSON for gating hooks)
// Registered in ~/.gemini/settings.json by hooks/gemini-install.js
// BeforeTool: gates tool execution via /permission bubble (blocking)

const { postStateToRunningServer, postPermissionToRunningServer } = require("./server-config");
const { createPidResolver, readStdinJson, getPlatformConfig } = require("./shared-process");

// Gemini hook event → { state, event } for the Clawd state machine
const HOOK_MAP = {
  SessionStart:  { state: "idle",         event: "SessionStart" },
  SessionEnd:    { state: "sleeping",     event: "SessionEnd" },
  BeforeAgent:   { state: "thinking",     event: "UserPromptSubmit" },
  BeforeTool:    { state: "working",      event: "PreToolUse" },
  AfterTool:     { state: "working",      event: "PostToolUse" },
  AfterAgent:    { state: "attention",    event: "Stop" },
  Notification:  { state: "notification", event: "Notification" },
  PreCompress:   { state: "sweeping",     event: "PreCompact" },
};

const config = getPlatformConfig();
const resolve = createPidResolver({
  agentNames: { win: new Set(["gemini.exe"]), mac: new Set(["gemini"]), linux: new Set(["gemini"]) },
  platformConfig: config,
});

// Gemini CLI gating hooks need stdout JSON response
function stdoutForEvent(hookName) {
  if (hookName === "BeforeTool") return JSON.stringify({ decision: "allow" });
  if (hookName === "BeforeAgent") return JSON.stringify({});
  return "{}";
}

readStdinJson().then((payload) => {
  const hookName = (payload && payload.hook_event_name) || "";
  const mapped = HOOK_MAP[hookName];

  if (!mapped) {
    process.stdout.write(stdoutForEvent(hookName) + "\n");
    process.exit(0);
    return;
  }

  const { state, event } = mapped;
  if (hookName === "SessionStart" && !process.env.CLAWD_REMOTE) resolve();

  const sessionId = (payload && payload.session_id) || "default";
  const cwd = (payload && payload.cwd) || "";

  const { stablePid, agentPid, detectedEditor, pidChain } = resolve();

  const stateBody = { state, session_id: sessionId, event };
  stateBody.agent_id = "gemini-cli";
  if (cwd) stateBody.cwd = cwd;
  if (process.env.CLAWD_REMOTE) {
    const { readHostPrefix } = require("./server-config");
    stateBody.host = readHostPrefix();
  } else {
    stateBody.source_pid = stablePid;
    if (detectedEditor) stateBody.editor = detectedEditor;
    if (agentPid) stateBody.agent_pid = agentPid;
    if (pidChain.length) stateBody.pid_chain = pidChain;
  }

  // BeforeTool: send state update (fire-and-forget) then block on permission bubble
  if (hookName === "BeforeTool") {
    postStateToRunningServer(JSON.stringify(stateBody), { timeoutMs: 100 }, () => {});

    const toolName = (payload && payload.tool_name) || "Unknown";
    let toolInput = {};
    try {
      const raw = payload.tool_args || payload.tool_input;
      toolInput = typeof raw === "string" ? JSON.parse(raw) : (raw || {});
    } catch {}

    const permBody = {
      tool_name: toolName,
      tool_input: toolInput,
      session_id: sessionId,
      agent_id: "gemini-cli",
    };

    postPermissionToRunningServer(JSON.stringify(permBody), {}, (err, data) => {
      if (err || !data) {
        process.stdout.write(JSON.stringify({ decision: "allow" }) + "\n");
        process.exit(0);
        return;
      }

      let behavior = "allow";
      if (data.hookSpecificOutput && data.hookSpecificOutput.decision) {
        behavior = data.hookSpecificOutput.decision.behavior || "allow";
      } else if (data.behavior) {
        behavior = data.behavior;
      }

      process.stdout.write(JSON.stringify({ decision: behavior === "deny" ? "deny" : "allow" }) + "\n");
      process.exit(0);
    });
    return;
  }

  // All other events: fire-and-forget state update
  const outLine = stdoutForEvent(hookName);
  postStateToRunningServer(JSON.stringify(stateBody), { timeoutMs: 100 }, () => {
    process.stdout.write(outLine + "\n");
    process.exit(0);
  });
});
