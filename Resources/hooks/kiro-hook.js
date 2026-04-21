#!/usr/bin/env node
// Clawd — Kiro CLI hook (stdin JSON with hook_event_name; exit code gating)
// Registered in ~/.kiro/agents/clawd.json by hooks/kiro-install.js
// preToolUse: gates tool execution via /permission bubble (blocking)

const { postStateToRunningServer, postPermissionToRunningServer } = require("./server-config");
const { createPidResolver, readStdinJson, getPlatformConfig } = require("./shared-process");

// Kiro CLI hook event → { state, event } for the Clawd state machine
const HOOK_MAP = {
  agentSpawn:       { state: "idle",      event: "agentSpawn" },
  userPromptSubmit: { state: "thinking",  event: "userPromptSubmit" },
  preToolUse:       { state: "working",   event: "preToolUse" },
  postToolUse:      { state: "working",   event: "postToolUse" },
  stop:             { state: "attention", event: "stop" },
};

const config = getPlatformConfig();
const resolve = createPidResolver({
  agentNames: { win: new Set(["kiro.exe"]), mac: new Set(["kiro"]), linux: new Set(["kiro"]) },
  platformConfig: config,
});

readStdinJson().then((payload) => {
  const hookName = (payload && payload.hook_event_name) || "";
  const mapped = HOOK_MAP[hookName];
  if (!mapped) {
    process.exit(0);
    return;
  }

  const { state, event } = mapped;
  if (hookName === "agentSpawn" && !process.env.CLAWD_REMOTE) resolve();

  const sessionId = "default";
  const cwd = (payload && payload.cwd) || "";

  const { stablePid, agentPid, detectedEditor, pidChain } = resolve();

  const stateBody = { state, session_id: sessionId, event };
  stateBody.agent_id = "kiro-cli";
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

  // preToolUse: send state update (fire-and-forget) then block on permission bubble
  if (hookName === "preToolUse") {
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
      agent_id: "kiro-cli",
    };

    postPermissionToRunningServer(JSON.stringify(permBody), {}, (err, data) => {
      if (err || !data) {
        // Clawd unavailable — allow by default (exit 0)
        process.exit(0);
        return;
      }

      let behavior = "allow";
      if (data.hookSpecificOutput && data.hookSpecificOutput.decision) {
        behavior = data.hookSpecificOutput.decision.behavior || "allow";
      } else if (data.behavior) {
        behavior = data.behavior;
      }

      // Kiro uses exit code: 0 = allow, 1 = deny
      process.exit(behavior === "deny" ? 1 : 0);
    });
    return;
  }

  // All other events: fire-and-forget state update
  postStateToRunningServer(JSON.stringify(stateBody), { timeoutMs: 100 }, () => {
    process.exit(0);
  });
});
