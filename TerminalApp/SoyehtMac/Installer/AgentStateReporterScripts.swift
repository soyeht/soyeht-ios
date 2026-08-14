import Foundation

/// Reporter scripts installed into agent config directories by
/// `AgentStateIntegrationInstaller`. Kept as source-of-truth string constants
/// so the installed copies always match the app build (herdr does the same
/// with its bundled integration assets).
///
/// All reporters are env-gated: they only act when `SOYEHT_CONVERSATION_ID`
/// and `SOYEHT_AUTOMATION_DIR` are present (injected into Soyeht panes), so
/// they are inert no-ops for agent sessions running outside Soyeht.
enum AgentStateReporterScripts {
    static let version = 10

    /// Shared hook reporter for Claude Code, Codex and Qwen Code hooks (agent
    /// selected via `SOYEHT_REPORT_AGENT`). Reads the hook JSON on stdin and
    /// writes a fire-and-forget `report_agent_state` request. Never blocks or
    /// fails the agent: any error exits 0 silently.
    static let claudeCodexHookReporter = #"""
#!/usr/bin/env python3
# Managed by Soyeht (agent-state integration v3). Do not edit.
# Reports agent lifecycle to the Soyeht automation directory inherited from
# the pane environment. Active only inside a Soyeht pane. Fire-and-forget.
import json, os, sys, time, uuid
from pathlib import Path


def main():
    conversation_id = os.environ.get("SOYEHT_CONVERSATION_ID", "")
    automation_dir = os.environ.get("SOYEHT_AUTOMATION_DIR", "")
    if not conversation_id or not automation_dir:
        return 0
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
    except Exception:
        data = {}
    event = str(data.get("hook_event_name") or "")
    tool_name = str(data.get("tool_name") or "")
    tool_input = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
    command = str(tool_input.get("command") or "")
    snippet = (command[:120] + "...") if len(command) > 120 else command
    notification_type = str(data.get("notification_type") or "")

    state = None
    message = None
    if event in ("UserPromptSubmit", "PreToolUse", "PostToolUse"):
        state = "working"
        message = tool_name or None
    elif event == "PermissionRequest":
        state = "blocked"
        message = ("aprovar %s: %s" % (tool_name, snippet)) if snippet else ("aprovar %s" % tool_name)
    elif event == "Notification":
        # qwen Notification carries notification_type: permission_prompt ->
        # blocked; idle_prompt -> idle (turn done); anything else (e.g.
        # auth_success) is informational and ignored. Claude/codex have no
        # notification_type and keep the legacy blocked mapping.
        if notification_type == "idle_prompt":
            state = "idle"
        elif notification_type and notification_type != "permission_prompt":
            return 0
        else:
            state = "blocked"
            message = str(data.get("message") or "agente pediu atencao")[:160]
    elif event in ("Stop", "SessionEnd"):
        state = "idle"
    elif event == "SessionStart":
        state = "idle"
        message = "ready"
    if not state:
        return 0

    payload = {
        "state": state,
        "sourceConversationID": conversation_id,
        "reportSource": "hook:" + os.environ.get("SOYEHT_REPORT_AGENT", "agent"),
        "seq": time.time_ns(),
    }
    if message:
        payload["message"] = message
    nonce = os.environ.get("SOYEHT_LAUNCH_NONCE", "")
    if nonce:
        payload["nonce"] = nonce
    request = {"id": str(uuid.uuid4()), "type": "report_agent_state", "payload": payload}
    requests_dir = Path(automation_dir) / "Requests"
    requests_dir.mkdir(parents=True, exist_ok=True)
    request_id = request["id"]
    tmp = requests_dir / (".%s.tmp" % request_id)
    tmp.write_text(json.dumps(request))
    tmp.rename(requests_dir / ("%s.json" % request_id))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
"""#

    /// Antigravity CLI (agy) hook reporter, shipped as an agy plugin. agy
    /// hook payloads have no event field, so the event is passed in
    /// `SOYEHT_HOOK_EVENT` by the hooks.json command. Payload is camelCase
    /// (`toolCall`, `terminationReason`, `fullyIdle`). There is no startup
    /// event: the first report only fires after the user's first prompt
    /// (PreInvocation), so agy launches use legacy timed prompt delivery
    /// instead of nonce gating.
    static let antigravityHookReporter = #"""
#!/usr/bin/env python3
# Managed by Soyeht (agent-state integration v4). Do not edit.
# Antigravity CLI (agy) hook reporter. Event name arrives via
# SOYEHT_HOOK_EVENT (agy payloads have no hook_event_name field). Reads the
# hook JSON on stdin (camelCase) and writes a fire-and-forget
# report_agent_state request. Active only inside a Soyeht pane.
import json, os, sys, time, uuid
from pathlib import Path


def main():
    conversation_id = os.environ.get("SOYEHT_CONVERSATION_ID", "")
    automation_dir = os.environ.get("SOYEHT_AUTOMATION_DIR", "")
    if not conversation_id or not automation_dir:
        return 0
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
    except Exception:
        data = {}
    event = os.environ.get("SOYEHT_HOOK_EVENT", "")
    tool_call = data.get("toolCall") if isinstance(data.get("toolCall"), dict) else {}
    tool_name = str(tool_call.get("name") or "")
    args = tool_call.get("args") if isinstance(tool_call.get("args"), dict) else {}
    command = str(args.get("CommandLine") or args.get("command") or "")
    snippet = (command[:120] + "...") if len(command) > 120 else command

    state = None
    message = None
    if event in ("PreInvocation", "PreToolUse", "PostToolUse", "PostInvocation"):
        state = "working"
        message = tool_name or None
    elif event == "Stop":
        state = "idle"
        reason = str(data.get("terminationReason") or "")
        fully_idle = bool(data.get("fullyIdle", True))
        message = reason if fully_idle else ("%s (tarefas em background)" % reason if reason else "tarefas em background")
    if not state:
        return 0
    if snippet and state == "working":
        message = ("%s: %s" % (tool_name, snippet))[:160] if tool_name else snippet[:160]

    payload = {
        "state": state,
        "sourceConversationID": conversation_id,
        "reportSource": "hook:" + os.environ.get("SOYEHT_REPORT_AGENT", "antigravity"),
        "seq": time.time_ns(),
    }
    if message:
        payload["message"] = message
    nonce = os.environ.get("SOYEHT_LAUNCH_NONCE", "")
    if nonce:
        payload["nonce"] = nonce
    request = {"id": str(uuid.uuid4()), "type": "report_agent_state", "payload": payload}
    requests_dir = Path(automation_dir) / "Requests"
    requests_dir.mkdir(parents=True, exist_ok=True)
    request_id = request["id"]
    tmp = requests_dir / (".%s.tmp" % request_id)
    tmp.write_text(json.dumps(request))
    tmp.rename(requests_dir / ("%s.json" % request_id))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
"""#

    /// agy plugin manifest for the antigravity reporter plugin.
    static let antigravityPluginManifest = #"""
{
  "$schema": "https://antigravity.google/schemas/v1/plugin.json",
  "name": "soyeht-agent-state",
  "description": "Reports Antigravity CLI agent lifecycle to the Soyeht automation directory. Env-gated: inert outside Soyeht panes."
}
"""#

    /// agy plugin hooks.json. Named-hook schema: PreToolUse/PostToolUse use
    /// the grouped matcher form; PreInvocation/PostInvocation/Stop are flat
    /// handler lists. The event is injected via SOYEHT_HOOK_EVENT because agy
    /// payloads carry no event name. `__REPORTER__` is replaced with the
    /// installed reporter path.
    static let antigravityPluginHooks = #"""
{
  "soyeht-agent-state": {
    "PreInvocation": [
      {
        "type": "command",
        "command": "SOYEHT_REPORT_AGENT=antigravity SOYEHT_HOOK_EVENT=PreInvocation python3 \"__REPORTER__\"",
        "timeout": 10
      }
    ],
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "SOYEHT_REPORT_AGENT=antigravity SOYEHT_HOOK_EVENT=PreToolUse python3 \"__REPORTER__\"",
            "timeout": 10
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "SOYEHT_REPORT_AGENT=antigravity SOYEHT_HOOK_EVENT=PostToolUse python3 \"__REPORTER__\"",
            "timeout": 10
          }
        ]
      }
    ],
    "PostInvocation": [
      {
        "type": "command",
        "command": "SOYEHT_REPORT_AGENT=antigravity SOYEHT_HOOK_EVENT=PostInvocation python3 \"__REPORTER__\"",
        "timeout": 10
      }
    ],
    "Stop": [
      {
        "type": "command",
        "command": "SOYEHT_REPORT_AGENT=antigravity SOYEHT_HOOK_EVENT=Stop python3 \"__REPORTER__\"",
        "timeout": 10
      }
    ]
  }
}
"""#

    /// pi (earendil) extension reporter. pi auto-discovers TS extensions in
    /// ~/.pi/agent/extensions/. Lifecycle events: session_start fires at
    /// boot (handshake), agent_start/turn_start/tool_execution_start mean
    /// working, agent_end/agent_settled mean idle, session_shutdown done.
    /// pi has no permission system, so there is no blocked state.
    static let piExtensionReporter = #"""
// Managed by Soyeht (agent-state integration v5). Do not edit.
// pi (earendil) extension reporter. Reports agent lifecycle to the Soyeht
// automation directory inherited from the pane environment. Active only
// inside a Soyeht pane. Fire-and-forget.
import { mkdir, rename, writeFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { join } from "node:path";

export default function (pi: any) {
  const enabled = () => Boolean(process.env.SOYEHT_CONVERSATION_ID && process.env.SOYEHT_AUTOMATION_DIR);

  async function report(state: string, message?: string) {
    if (!enabled() || !state) return;
    try {
      const payload: Record<string, unknown> = {
        state,
        sourceConversationID: process.env.SOYEHT_CONVERSATION_ID,
        reportSource: "hook:pi",
        seq: Date.now() * 1000 + Math.floor(Math.random() * 1000),
      };
      if (message) payload.message = String(message).slice(0, 200);
      if (process.env.SOYEHT_LAUNCH_NONCE) payload.nonce = process.env.SOYEHT_LAUNCH_NONCE;
      const dir = join(process.env.SOYEHT_AUTOMATION_DIR as string, "Requests");
      await mkdir(dir, { recursive: true });
      const id = randomUUID();
      const tmp = join(dir, `.${id}.tmp`);
      await writeFile(tmp, JSON.stringify({ id, type: "report_agent_state", payload }));
      await rename(tmp, join(dir, `${id}.json`));
    } catch {
      // never disturb the agent session
    }
  }

  pi.on("session_start", async () => { await report("idle", "ready"); });
  pi.on("agent_start", async () => { await report("working"); });
  pi.on("turn_start", async () => { await report("working"); });
  pi.on("tool_execution_start", async (event: any) => {
    await report("working", event?.toolName ?? event?.name);
  });
  pi.on("agent_end", async () => { await report("idle"); });
  pi.on("agent_settled", async () => { await report("idle"); });
  pi.on("session_shutdown", async () => { await report("done"); });
}
"""#

    /// Kilo Code CLI plugin reporter. Kilo is an OpenCode fork with the same
    /// plugin API and event names, so this mirrors the OpenCode plugin.
    static let kiloPluginReporter = #"""
// Managed by Soyeht (agent-state integration v6). Do not edit.
// Reports agent lifecycle to the Soyeht automation directory inherited from
// the pane environment. Active only inside a Soyeht pane. Fire-and-forget.
import { randomUUID } from "node:crypto";
import { mkdir, writeFile, rename } from "node:fs/promises";
import { join } from "node:path";

const SOURCE = "hook:kilo";
const BUSY_STATUSES = new Set([
  "active", "busy", "pending", "retry", "running", "streaming", "working",
]);

const pendingPermissions = new Set();
let lastBaseState = null;
let lastBlockedMessage = null;

async function report(state, message) {
  const conversationID = process.env.SOYEHT_CONVERSATION_ID;
  const automationDir = process.env.SOYEHT_AUTOMATION_DIR;
  if (!conversationID || !automationDir || !state) return;
  const id = randomUUID();
  const payload = {
    state,
    sourceConversationID: conversationID,
    reportSource: SOURCE,
    seq: Date.now() * 1000 + Math.floor(Math.random() * 1000),
  };
  if (message) payload.message = String(message).slice(0, 200);
  const nonce = process.env.SOYEHT_LAUNCH_NONCE;
  if (nonce) payload.nonce = nonce;
  try {
    const dir = join(automationDir, "Requests");
    await mkdir(dir, { recursive: true });
    const tmp = join(dir, `.${id}.tmp`);
    await writeFile(tmp, JSON.stringify({ id, type: "report_agent_state", payload }));
    await rename(tmp, join(dir, `${id}.json`));
  } catch {
    // never disturb the agent session
  }
}

async function publish(message) {
  if (pendingPermissions.size > 0) {
    await report("blocked", message ?? lastBlockedMessage ?? "agente aguardando aprovacao");
    return;
  }
  const state = lastBaseState;
  if (state) await report(state, message);
}

export const SoyehtAgentStatePlugin = async () => {
  if (!process.env.SOYEHT_CONVERSATION_ID || !process.env.SOYEHT_AUTOMATION_DIR) {
    return {};
  }
  lastBaseState = "idle";
  await report("idle", "ready");
  return {
    "chat.message": async () => {
      lastBaseState = "working";
      await publish();
    },
    "tool.execute.before": async () => {
      lastBaseState = "working";
      await publish();
    },
    event: async ({ event }) => {
      const type = event?.type;
      const properties = event?.properties ?? {};
      const permId = properties?.id ?? properties?.permissionID ?? properties?.requestID;
      switch (type) {
        case "session.created":
          lastBaseState = lastBaseState ?? "idle";
          await publish();
          break;
        case "session.status": {
          const status = properties.status;
          const kind = (typeof status === "string" ? status : status?.type ?? "").toLowerCase();
          if (kind === "idle") lastBaseState = "idle";
          else if (BUSY_STATUSES.has(kind)) lastBaseState = "working";
          await publish();
          break;
        }
        case "permission.asked":
        case "permission.updated":
          pendingPermissions.add(String(permId ?? `anon:${randomUUID()}`));
          lastBlockedMessage = `aprovar ${properties?.tool ?? properties?.title ?? "tool"}`;
          await report("blocked", lastBlockedMessage);
          break;
        case "permission.replied":
        case "permission.resolved":
          if (permId) pendingPermissions.delete(String(permId));
          else pendingPermissions.clear();
          if (pendingPermissions.size === 0) lastBlockedMessage = null;
          await publish("permissao resolvida");
          break;
        case "question.asked":
          pendingPermissions.add(`question:${permId ?? randomUUID()}`);
          lastBlockedMessage = "responder pergunta do agente";
          await report("blocked", lastBlockedMessage);
          break;
        case "question.replied":
        case "question.rejected":
          for (const key of [...pendingPermissions]) {
            if (key.startsWith("question:")) pendingPermissions.delete(key);
          }
          await publish();
          break;
        case "session.error":
          await report("blocked", String(properties?.error ?? "erro na sessao").slice(0, 160));
          break;
        case "session.idle":
          lastBaseState = "idle";
          await publish();
          break;
        case "tool.execute.after":
        case "session.compacted":
          await publish();
          break;
        default:
          break;
      }
    },
  };
};
"""#

    /// Cursor CLI hook reporter. Cursor hook payloads arrive on stdin as JSON
    /// with hookEventName/hook_event_name (sessionStart, beforeSubmitPrompt,
    /// beforeShellExecution, beforeMCPExecution, stop, sessionEnd). Cursor
    /// has no hook event for the approval prompt itself, so blocked is only
    /// visible on screen. Fire-and-forget.
    static let cursorHookReporter = #"""
#!/usr/bin/env python3
# Managed by Soyeht (agent-state integration v7). Do not edit.
# Cursor CLI hook reporter. Fire-and-forget.
import json, os, sys, time, uuid
from pathlib import Path


def main():
    conversation_id = os.environ.get("SOYEHT_CONVERSATION_ID", "")
    automation_dir = os.environ.get("SOYEHT_AUTOMATION_DIR", "")
    if not conversation_id or not automation_dir:
        return 0
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
    except Exception:
        data = {}
    event = str(data.get("hook_event_name") or data.get("hookEventName") or "")

    state = None
    message = None
    if event in ("beforeSubmitPrompt", "beforeShellExecution", "beforeMCPExecution", "beforeReadFile"):
        state = "working"
    elif event == "sessionStart":
        state = "idle"
        message = "ready"
    elif event == "stop":
        state = "idle"
    elif event == "sessionEnd":
        state = "done"
    if not state:
        return 0

    payload = {
        "state": state,
        "sourceConversationID": conversation_id,
        "reportSource": "hook:" + os.environ.get("SOYEHT_REPORT_AGENT", "cursor"),
        "seq": time.time_ns(),
    }
    if message:
        payload["message"] = message
    nonce = os.environ.get("SOYEHT_LAUNCH_NONCE", "")
    if nonce:
        payload["nonce"] = nonce
    request = {"id": str(uuid.uuid4()), "type": "report_agent_state", "payload": payload}
    requests_dir = Path(automation_dir) / "Requests"
    requests_dir.mkdir(parents=True, exist_ok=True)
    request_id = request["id"]
    tmp = requests_dir / (".%s.tmp" % request_id)
    tmp.write_text(json.dumps(request))
    tmp.rename(requests_dir / ("%s.json" % request_id))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
"""#

    /// GitHub Copilot CLI hook reporter. Copilot hook payloads carry no event
    /// name; the event arrives via SOYEHT_HOOK_EVENT (set per hook entry in
    /// the hooks.json env). Fire-and-forget.
    static let copilotHookReporter = #"""
#!/usr/bin/env python3
# Managed by Soyeht (agent-state integration v8). Do not edit.
# GitHub Copilot CLI hook reporter. Fire-and-forget.
import json, os, sys, time, uuid
from pathlib import Path


def main():
    conversation_id = os.environ.get("SOYEHT_CONVERSATION_ID", "")
    automation_dir = os.environ.get("SOYEHT_AUTOMATION_DIR", "")
    if not conversation_id or not automation_dir:
        return 0
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
    except Exception:
        data = {}
    event = os.environ.get("SOYEHT_HOOK_EVENT", "")

    state = None
    message = None
    if event in ("userPromptSubmitted", "preToolUse", "postToolUse"):
        state = "working"
        tool = str(data.get("toolName") or "")
        if tool:
            message = tool
    elif event == "sessionStart":
        state = "idle"
        message = "ready"
    elif event == "agentStop":
        state = "idle"
    elif event == "errorOccurred":
        state = "blocked"
        message = str(data.get("message") or data.get("error") or "erro na sessao")[:160]
    elif event == "sessionEnd":
        state = "done"
    if not state:
        return 0

    payload = {
        "state": state,
        "sourceConversationID": conversation_id,
        "reportSource": "hook:copilot",
        "seq": time.time_ns(),
    }
    if message:
        payload["message"] = message
    nonce = os.environ.get("SOYEHT_LAUNCH_NONCE", "")
    if nonce:
        payload["nonce"] = nonce
    request = {"id": str(uuid.uuid4()), "type": "report_agent_state", "payload": payload}
    requests_dir = Path(automation_dir) / "Requests"
    requests_dir.mkdir(parents=True, exist_ok=True)
    request_id = request["id"]
    tmp = requests_dir / (".%s.tmp" % request_id)
    tmp.write_text(json.dumps(request))
    tmp.rename(requests_dir / ("%s.json" % request_id))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
"""#

    /// Grok CLI hook reporter (lives in ~/.grok/hooks/). Grok reads Claude
    /// settings hooks too but executes hook commands WITHOUT a shell, so the
    /// command must be a bare executable path — no `VAR=x` prefix is allowed.
    /// reportSource is therefore hardcoded. Fire-and-forget.
    static let grokHookReporter = #"""
#!/usr/bin/env python3
# Managed by Soyeht (agent-state integration v9). Do not edit.
# Grok CLI hook reporter. Fire-and-forget.
import json, os, sys, time, uuid
from pathlib import Path


def main():
    conversation_id = os.environ.get("SOYEHT_CONVERSATION_ID", "")
    automation_dir = os.environ.get("SOYEHT_AUTOMATION_DIR", "")
    if not conversation_id or not automation_dir:
        return 0
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
    except Exception:
        data = {}
    event = str(data.get("hook_event_name") or "")

    state = None
    message = None
    if event in ("UserPromptSubmit", "PreToolUse", "PostToolUse"):
        state = "working"
        tool = str(data.get("tool_name") or "")
        if tool:
            message = tool
    elif event == "SessionStart":
        state = "idle"
        message = "ready"
    elif event == "Stop":
        state = "idle"
    elif event == "SessionEnd":
        state = "done"
    if not state:
        return 0

    payload = {
        "state": state,
        "sourceConversationID": conversation_id,
        "reportSource": "hook:grok",
        "seq": time.time_ns(),
    }
    if message:
        payload["message"] = message
    request = {"id": str(uuid.uuid4()), "type": "report_agent_state", "payload": payload}
    requests_dir = Path(automation_dir) / "Requests"
    requests_dir.mkdir(parents=True, exist_ok=True)
    request_id = request["id"]
    tmp = requests_dir / (".%s.tmp" % request_id)
    tmp.write_text(json.dumps(request))
    tmp.rename(requests_dir / ("%s.json" % request_id))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
"""#

    /// Kimi Code CLI hook reporter. Kimi hooks are configured as `[[hooks]]`
    /// entries in ~/.kimi-code/config.toml; payloads arrive on stdin with
    /// snake_case fields (Claude-style). reportSource hardcoded because the
    /// shell-command hook format is strict. Fire-and-forget.
    static let kimiHookReporter = #"""
#!/usr/bin/env python3
# Managed by Soyeht (agent-state integration v9). Do not edit.
# Kimi Code CLI hook reporter. Fire-and-forget.
import json, os, sys, time, uuid
from pathlib import Path


def main():
    conversation_id = os.environ.get("SOYEHT_CONVERSATION_ID", "")
    automation_dir = os.environ.get("SOYEHT_AUTOMATION_DIR", "")
    if not conversation_id or not automation_dir:
        return 0
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
    except Exception:
        data = {}
    event = str(data.get("hook_event_name") or "")
    tool_name = str(data.get("tool_name") or "")

    state = None
    message = None
    if event in ("UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure"):
        state = "working"
        message = tool_name or None
    elif event == "PermissionRequest":
        state = "blocked"
        if tool_name:
            message = "aprovar %s" % tool_name
    elif event == "PermissionResult":
        state = "working"
    elif event == "SessionStart":
        state = "idle"
        message = "ready"
    elif event == "Stop":
        state = "idle"
    elif event == "SessionEnd":
        state = "done"
    if not state:
        return 0

    payload = {
        "state": state,
        "sourceConversationID": conversation_id,
        "reportSource": "hook:kimi",
        "seq": time.time_ns(),
    }
    if message:
        payload["message"] = message
    request = {"id": str(uuid.uuid4()), "type": "report_agent_state", "payload": payload}
    requests_dir = Path(automation_dir) / "Requests"
    requests_dir.mkdir(parents=True, exist_ok=True)
    request_id = request["id"]
    tmp = requests_dir / (".%s.tmp" % request_id)
    tmp.write_text(json.dumps(request))
    tmp.rename(requests_dir / ("%s.json" % request_id))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
"""#

    /// Devin CLI hook reporter (Cognition). Devin payloads are Claude-style
    /// (hook_event_name on stdin) and include PermissionRequest. Fire-and-forget.
    static let devinHookReporter = #"""
#!/usr/bin/env python3
# Managed by Soyeht (agent-state integration v10). Do not edit.
# Devin CLI hook reporter. Fire-and-forget.
import json, os, sys, time, uuid
from pathlib import Path


def main():
    conversation_id = os.environ.get("SOYEHT_CONVERSATION_ID", "")
    automation_dir = os.environ.get("SOYEHT_AUTOMATION_DIR", "")
    if not conversation_id or not automation_dir:
        return 0
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
    except Exception:
        data = {}
    event = str(data.get("hook_event_name") or "")
    tool_name = str(data.get("tool_name") or "")

    state = None
    message = None
    if event in ("UserPromptSubmit", "PreToolUse", "PostToolUse"):
        state = "working"
        message = tool_name or None
    elif event == "PermissionRequest":
        state = "blocked"
        if tool_name:
            message = "aprovar %s" % tool_name
    elif event == "SessionStart":
        state = "idle"
        message = "ready"
    elif event == "Stop":
        state = "idle"
    elif event == "SessionEnd":
        state = "done"
    if not state:
        return 0

    payload = {
        "state": state,
        "sourceConversationID": conversation_id,
        "reportSource": "hook:devin",
        "seq": time.time_ns(),
    }
    if message:
        payload["message"] = message
    request = {"id": str(uuid.uuid4()), "type": "report_agent_state", "payload": payload}
    requests_dir = Path(automation_dir) / "Requests"
    requests_dir.mkdir(parents=True, exist_ok=True)
    request_id = request["id"]
    tmp = requests_dir / (".%s.tmp" % request_id)
    tmp.write_text(json.dumps(request))
    tmp.rename(requests_dir / ("%s.json" % request_id))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
"""#

    /// OpenCode plugin reporter. Models two dimensions (alaine's review):
    /// base session lifecycle from `session.status` plus an overlay of
    /// pending permissions keyed by permission id — a busy session status
    /// never clears a pending permission. Tolerant to event-format drift
    /// between OpenCode versions (legacy `permission.updated` included).
    static let opencodePluginReporter = #"""
// Managed by Soyeht (agent-state integration v1). Do not edit.
// Reports agent lifecycle to the Soyeht automation directory inherited from
// the pane environment. Active only inside a Soyeht pane. Fire-and-forget.
import { randomUUID } from "node:crypto";
import { mkdir, writeFile, rename } from "node:fs/promises";
import { join } from "node:path";

const SOURCE = "hook:opencode";
const BUSY_STATUSES = new Set([
  "active", "busy", "pending", "retry", "running", "streaming", "working",
]);

const pendingPermissions = new Set();
let lastBaseState = null;
let lastBlockedMessage = null;

async function report(state, message) {
  const conversationID = process.env.SOYEHT_CONVERSATION_ID;
  const automationDir = process.env.SOYEHT_AUTOMATION_DIR;
  if (!conversationID || !automationDir || !state) return;
  const id = randomUUID();
  const payload = {
    state,
    sourceConversationID: conversationID,
    reportSource: SOURCE,
    seq: Date.now() * 1000 + Math.floor(Math.random() * 1000),
  };
  if (message) payload.message = String(message).slice(0, 200);
  const nonce = process.env.SOYEHT_LAUNCH_NONCE;
  if (nonce) payload.nonce = nonce;
  try {
    const dir = join(automationDir, "Requests");
    await mkdir(dir, { recursive: true });
    const tmp = join(dir, `.${id}.tmp`);
    await writeFile(tmp, JSON.stringify({ id, type: "report_agent_state", payload }));
    await rename(tmp, join(dir, `${id}.json`));
  } catch {
    // never disturb the agent session
  }
}

async function publish(message) {
  if (pendingPermissions.size > 0) {
    // Keep the original blocked reason while permissions stay pending;
    // heartbeat events (session.status) must not erase it.
    await report("blocked", message ?? lastBlockedMessage ?? "agente aguardando aprovacao");
    return;
  }
  const state = lastBaseState;
  if (state) await report(state, message);
}

export const SoyehtAgentStatePlugin = async () => {
  if (!process.env.SOYEHT_CONVERSATION_ID || !process.env.SOYEHT_AUTOMATION_DIR) {
    return {};
  }
  // Plugin loaded inside a Soyeht pane: announce readiness (handshake).
  lastBaseState = "idle";
  await report("idle", "ready");
  return {
    "chat.message": async () => {
      lastBaseState = "working";
      await publish();
    },
    "tool.execute.before": async () => {
      lastBaseState = "working";
      await publish();
    },
    event: async ({ event }) => {
      const type = event?.type;
      const properties = event?.properties ?? {};
      const permId = properties?.id ?? properties?.permissionID ?? properties?.requestID;
      switch (type) {
        case "session.created":
          lastBaseState = lastBaseState ?? "idle";
          await publish();
          break;
        case "session.status": {
          const status = properties.status;
          const kind = (typeof status === "string" ? status : status?.type ?? "").toLowerCase();
          if (kind === "idle") lastBaseState = "idle";
          else if (BUSY_STATUSES.has(kind)) lastBaseState = "working";
          await publish();
          break;
        }
        case "permission.asked":
        case "permission.updated":
          pendingPermissions.add(String(permId ?? `anon:${randomUUID()}`));
          lastBlockedMessage = `aprovar ${properties?.tool ?? properties?.title ?? "tool"}`;
          await report("blocked", lastBlockedMessage);
          break;
        case "permission.replied":
        case "permission.resolved":
          if (permId) pendingPermissions.delete(String(permId));
          else pendingPermissions.clear();
          if (pendingPermissions.size === 0) lastBlockedMessage = null;
          await publish("permissao resolvida");
          break;
        case "question.asked":
          pendingPermissions.add(`question:${permId ?? randomUUID()}`);
          lastBlockedMessage = "responder pergunta do agente";
          await report("blocked", lastBlockedMessage);
          break;
        case "question.replied":
        case "question.rejected":
          for (const key of [...pendingPermissions]) {
            if (key.startsWith("question:")) pendingPermissions.delete(key);
          }
          await publish();
          break;
        case "session.error":
          await report("blocked", String(properties?.error ?? "erro na sessao").slice(0, 160));
          break;
        case "session.idle":
          lastBaseState = "idle";
          await publish();
          break;
        case "tool.execute.after":
        case "session.compacted":
          await publish();
          break;
        default:
          break;
      }
    },
  };
};
"""#
}
