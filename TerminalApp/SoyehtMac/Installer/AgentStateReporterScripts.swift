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
    static let version = 21

    /// Shared hook reporter for Claude Code, Codex and Qwen Code hooks (agent
    /// selected via `SOYEHT_REPORT_AGENT`). Reads the hook JSON on stdin and
    /// writes a fire-and-forget `report_agent_state` request. Never blocks or
    /// fails the agent: any error exits 0 silently.
    static let claudeCodexHookReporter = #"""
#!/usr/bin/env python3
# Managed by Soyeht (agent-state integration v21). Do not edit.
# Reports agent lifecycle to the Soyeht automation directory inherited from
# the pane environment. Active only inside a Soyeht pane. Fire-and-forget.
import hashlib, json, os, subprocess, sys, time, uuid
from pathlib import Path


def write_request(automation_dir, request_type, payload):
    request = {"id": str(uuid.uuid4()), "type": request_type, "payload": payload}
    requests_dir = Path(automation_dir) / "Requests"
    requests_dir.mkdir(parents=True, exist_ok=True)
    request_id = request["id"]
    tmp = requests_dir / (".%s.tmp" % request_id)
    tmp.write_text(json.dumps(request))
    tmp.rename(requests_dir / ("%s.json" % request_id))


def scalar(value, *keys):
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        for key in keys:
            candidate = value.get(key)
            if isinstance(candidate, str) and candidate:
                return candidate
    return None


def last_assistant_event(transcript_path):
    if not isinstance(transcript_path, str) or not transcript_path:
        return None
    try:
        with open(transcript_path, "rb") as handle:
            handle.seek(0, 2)
            size = handle.tell()
            # Devin exports ATIF as one JSON document. Read it whole within a
            # bounded size; other providers remain tail-parsed JSONL.
            handle.seek(0 if size <= 32_000_000 else max(0, size - 2_000_000))
            tail = handle.read().decode("utf-8", errors="replace")
    except Exception:
        return None
    try:
        document = json.loads(tail)
    except Exception:
        document = None
    if (
        isinstance(document, dict)
        and str(document.get("schema_version") or "").startswith("ATIF-")
        and isinstance(document.get("steps"), list)
    ):
        for step in reversed(document.get("steps")):
            if not isinstance(step, dict) or str(step.get("source") or "").lower() != "agent":
                continue
            text = step.get("message")
            if not isinstance(text, str) or not text.strip():
                continue
            session = str(document.get("session_id") or "")
            step_id = str(step.get("step_id") or "")
            source_event_id = "atif:%s:%s" % (session, step_id) if session or step_id else None
            model = scalar(step.get("model_name") or step.get("model"), "id", "model_id")
            return {
                "text": text.strip(),
                "sourceEventID": source_event_id,
                "model": model,
            }
    for line in reversed(tail.splitlines()):
        try:
            value = json.loads(line)
        except Exception:
            continue
        message = value.get("message") if isinstance(value, dict) else None
        if (
            not isinstance(message, dict)
            and isinstance(value, dict)
            and str(value.get("type") or "").lower() in ("assistant.message", "assistant_message")
            and isinstance(value.get("data"), dict)
        ):
            message = value.get("data")
        if not isinstance(message, dict):
            message = value if isinstance(value, dict) else {}
        value_type = str(value.get("type") or "").lower() if isinstance(value, dict) else ""
        is_antigravity_response = (
            value_type == "planner_response"
            and str(value.get("source") or "").lower() == "model"
        )
        role = (
            message.get("role")
            or (value.get("role") if isinstance(value, dict) else None)
            or (
                "assistant"
                if value_type in ("assistant.message", "assistant_message") or is_antigravity_response
                else None
            )
        )
        if str(role or "").lower() != "assistant":
            continue
        content = message.get("content")
        text = None
        if isinstance(content, str) and content.strip():
            text = content.strip()
        elif isinstance(content, list):
            texts = [
                str(part.get("text"))
                for part in content
                if isinstance(part, dict)
                and part.get("type") in ("text", "output_text")
                and isinstance(part.get("text"), str)
            ]
            joined = "\n".join(texts).strip()
            if joined:
                text = joined
        if text:
            source_event_id = scalar(
                message.get("messageId")
                or message.get("message_id")
                or message.get("id")
                or (value.get("id") if isinstance(value, dict) else None),
                "id"
            )
            if not source_event_id and is_antigravity_response:
                stable_parts = (
                    str(value.get("created_at") or ""),
                    str(value.get("step_index") or ""),
                    value_type,
                )
                source_event_id = "agy:" + hashlib.sha256(
                    ":".join(stable_parts).encode("utf-8")
                ).hexdigest()
            model = scalar(
                message.get("model") or message.get("modelId") or message.get("model_id"),
                "id", "model_id", "display_name"
            )
            return {"text": text, "sourceEventID": source_event_id, "model": model}
    return None


def last_assistant_text(transcript_path):
    event = last_assistant_event(transcript_path)
    return event.get("text") if event else None


def last_turn_metadata(transcript_path):
    if not isinstance(transcript_path, str) or not transcript_path:
        return {}
    try:
        with open(transcript_path, "rb") as handle:
            handle.seek(0, 2)
            size = handle.tell()
            handle.seek(max(0, size - 2_000_000))
            tail = handle.read().decode("utf-8", errors="replace")
    except Exception:
        return {}
    for line in reversed(tail.splitlines()):
        try:
            value = json.loads(line)
        except Exception:
            continue
        if not isinstance(value, dict) or str(value.get("type") or "").lower() != "turn_context":
            continue
        payload = value.get("payload") if isinstance(value.get("payload"), dict) else value
        model = scalar(payload.get("model"), "id", "model_id", "display_name")
        effort = scalar(
            payload.get("effort") or payload.get("reasoning_effort") or payload.get("reasoningEffort"),
            "level", "effective"
        )
        return {"model": model, "reasoningEffort": effort}
    return {}


def assistant_event_signature(event):
    if not event:
        return ""
    if event.get("sourceEventID"):
        return "id:" + str(event.get("sourceEventID"))
    return "sha256:" + hashlib.sha256(str(event.get("text") or "").encode("utf-8")).hexdigest()


def schedule_deferred_agent_transcript(transcript_path, session_id):
    if not isinstance(transcript_path, str) or not transcript_path:
        return False
    baseline = assistant_event_signature(last_assistant_event(transcript_path))
    env = os.environ.copy()
    env["SOYEHT_DEFERRED_AGENT_TRANSCRIPT"] = "1"
    env["SOYEHT_DEFERRED_TRANSCRIPT_PATH"] = transcript_path
    env["SOYEHT_DEFERRED_BASELINE"] = baseline
    if session_id:
        env["SOYEHT_DEFERRED_SESSION_ID"] = session_id
    try:
        subprocess.Popen(
            [sys.executable, os.path.abspath(__file__)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            close_fds=True,
            start_new_session=True,
            env=env,
        )
        return True
    except Exception:
        return False


def report_deferred_agent_transcript():
    conversation_id = os.environ.get("SOYEHT_CONVERSATION_ID", "")
    automation_dir = os.environ.get("SOYEHT_AUTOMATION_DIR", "")
    transcript_path = os.environ.get("SOYEHT_DEFERRED_TRANSCRIPT_PATH", "")
    baseline = os.environ.get("SOYEHT_DEFERRED_BASELINE", "")
    if not conversation_id or not automation_dir or not transcript_path:
        return 0
    for _ in range(50):
        event = last_assistant_event(transcript_path)
        if event and assistant_event_signature(event) != baseline:
            payload = {
                "sourceConversationID": conversation_id,
                "role": "assistant",
                "text": event.get("text"),
                "sourceEventID": event.get("sourceEventID"),
                "model": event.get("model"),
                "nativeSessionID": os.environ.get("SOYEHT_DEFERRED_SESSION_ID"),
            }
            payload = {key: value for key, value in payload.items() if value}
            write_request(automation_dir, "report_agent_conversation", payload)
            return 0
        time.sleep(0.1)
    return 0


def report_conversation(data, event, conversation_id, automation_dir):
    session_id = scalar(
        data.get("session_id") or data.get("sessionId") or data.get("conversationId"),
        "id"
    )
    model = scalar(
        data.get("model") or data.get("model_id") or data.get("modelId") or data.get("modelName"),
        "id", "model_id", "display_name"
    )
    effort = scalar(
        data.get("effort") or data.get("reasoning_effort") or data.get("reasoningEffort"),
        "level", "effective"
    )
    variant = scalar(data.get("variant"), "id", "name")
    payload = {
        "sourceConversationID": conversation_id,
        "nativeSessionID": session_id,
        "model": model,
        "reasoningEffort": effort,
        "variant": variant,
    }
    payload = {key: value for key, value in payload.items() if value}

    role = None
    text = None
    transcript_event = None
    if event == "UserPromptSubmit":
        role = "user"
        text = data.get("prompt") or data.get("user_prompt") or data.get("userPrompt")
        if not text and isinstance(data.get("input"), str):
            text = data.get("input")
    elif event == "MessageDisplay":
        role = "assistant"
        text = data.get("message") or data.get("text")
    elif event == "Stop":
        role = "assistant"
        text = data.get("last_assistant_message") or data.get("lastAssistantMessage")
        if not text:
            for candidate in (data.get("response"), data.get("output")):
                if isinstance(candidate, str) and candidate.strip():
                    text = candidate
                    break
        transcript_path = (
            data.get("transcript_path")
            or data.get("transcriptPath")
            or os.environ.get("SOYEHT_AGENT_TRANSCRIPT_PATH")
        )
        turn_metadata = last_turn_metadata(transcript_path)
        model = model or turn_metadata.get("model")
        effort = effort or turn_metadata.get("reasoningEffort")
        if model:
            payload["model"] = model
        if effort:
            payload["reasoningEffort"] = effort
        report_agent = os.environ.get("SOYEHT_REPORT_AGENT", "agent")
        if not text and report_agent in ("copilot", "devin") and schedule_deferred_agent_transcript(
            transcript_path, session_id
        ):
            role = None
        elif not text:
            transcript_event = last_assistant_event(transcript_path)
            if transcript_event:
                text = transcript_event.get("text")
                model = model or transcript_event.get("model")
                if model:
                    payload["model"] = model

    if isinstance(text, str) and text.strip():
        # A handoff envelope is transport already represented by its original
        # canonical events. It must not become a second user turn.
        if role == "user" and text.lstrip().startswith("SOYEHT_AGENT_HANDOFF_"):
            return
        payload["role"] = role
        payload["text"] = text
        source_event_id = (
            data.get("message_id")
            or data.get("messageId")
            or (transcript_event.get("sourceEventID") if transcript_event else None)
        )
        turn_id = (
            data.get("turn_id")
            or data.get("turnId")
            or data.get("generation_id")
            or data.get("generationId")
            or data.get("interactionId")
        )
        if not source_event_id and turn_id:
            source_event_id = "%s:%s" % (turn_id, role)
        if source_event_id:
            payload["sourceEventID"] = str(source_event_id)
        write_request(automation_dir, "report_agent_conversation", payload)
    elif any(payload.get(key) for key in (
        "nativeSessionID", "model", "reasoningEffort", "variant"
    )):
        write_request(automation_dir, "report_agent_conversation", payload)


def main():
    if os.environ.get("SOYEHT_DEFERRED_AGENT_TRANSCRIPT") == "1":
        return report_deferred_agent_transcript()
    conversation_id = os.environ.get("SOYEHT_CONVERSATION_ID", "")
    automation_dir = os.environ.get("SOYEHT_AUTOMATION_DIR", "")
    if not conversation_id or not automation_dir:
        return 0
    report_agent = os.environ.get("SOYEHT_REPORT_AGENT", "agent")
    declared_agent = os.environ.get("SOYEHT_AGENT_NAME", "")
    # Some Claude-compatible CLIs also load the user's global Claude hooks.
    # Ignore a reporter whose integration identity does not match the agent
    # Soyeht actually launched in this pane.
    if declared_agent and report_agent != declared_agent:
        return 0
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
    except Exception:
        data = {}
    raw_event = str(
        data.get("hook_event_name")
        or data.get("hookEventName")
        or os.environ.get("SOYEHT_HOOK_EVENT", "")
    )
    event = {
        "sessionStart": "SessionStart",
        "PreInvocation": "UserPromptSubmit",
        "PostInvocation": "PostToolUse",
        "userPromptSubmitted": "UserPromptSubmit",
        "beforeSubmitPrompt": "UserPromptSubmit",
        "preToolUse": "PreToolUse",
        "beforeShellExecution": "PreToolUse",
        "beforeMCPExecution": "PreToolUse",
        "beforeReadFile": "PreToolUse",
        "postToolUse": "PostToolUse",
        "agentStop": "Stop",
        "stop": "Stop",
        "sessionEnd": "SessionEnd",
    }.get(raw_event, raw_event)
    tool_name = str(data.get("tool_name") or data.get("toolName") or "")
    raw_tool_input = data.get("tool_input") or data.get("toolInput")
    tool_input = raw_tool_input if isinstance(raw_tool_input, dict) else {}
    command = str(tool_input.get("command") or "")
    snippet = (command[:120] + "...") if len(command) > 120 else command
    notification_type = str(data.get("notification_type") or "")

    if event in ("SessionStart", "UserPromptSubmit", "MessageDisplay", "Stop"):
        report_conversation(data, event, conversation_id, automation_dir)

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
    elif event == "Stop":
        state = "idle"
    elif event == "SessionEnd":
        state = "done"
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
    write_request(automation_dir, "report_agent_state", payload)
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

  async function writeRequest(type: string, payload: Record<string, unknown>) {
    if (!enabled()) return;
    const dir = join(process.env.SOYEHT_AUTOMATION_DIR as string, "Requests");
    await mkdir(dir, { recursive: true });
    const id = randomUUID();
    const tmp = join(dir, `.${id}.tmp`);
    await writeFile(tmp, JSON.stringify({ id, type, payload }));
    await rename(tmp, join(dir, `${id}.json`));
  }

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
      await writeRequest("report_agent_state", payload);
    } catch {
      // never disturb the agent session
    }
  }

  pi.on("session_start", async () => { await report("idle", "ready"); });
  pi.on("agent_start", async () => { await report("working"); });
  pi.on("turn_start", async () => { await report("working"); });
  pi.on("message_end", async (event: any) => {
    try {
      const message = event?.message;
      const role = message?.role;
      if (role !== "user" && role !== "assistant") return;
      const content = message?.content;
      const text = typeof content === "string"
        ? content.trim()
        : (Array.isArray(content)
          ? content
              .filter((part: any) => part?.type === "text" && typeof part?.text === "string")
              .map((part: any) => part.text)
              .join("\n")
              .trim()
          : "");
      if (!text || (role === "user" && text.startsWith("SOYEHT_AGENT_HANDOFF_"))) return;
      const payload: Record<string, unknown> = {
        sourceConversationID: process.env.SOYEHT_CONVERSATION_ID,
        role,
        text,
        sourceEventID: message?.id ?? message?.responseId
          ?? (message?.timestamp ? `${message.timestamp}:${role}` : undefined),
        model: message?.provider && message?.model
          ? `${message.provider}/${message.model}`
          : message?.model,
      };
      await writeRequest("report_agent_conversation", payload);
    } catch {
      // never disturb the agent session
    }
  });
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
const messageInfo = new Map();
const pendingTextParts = new Map();
let lastBaseState = null;
let lastBlockedMessage = null;

async function writeAutomationRequest(type, payload) {
  const automationDir = process.env.SOYEHT_AUTOMATION_DIR;
  if (!automationDir) return;
  const id = randomUUID();
  try {
    const dir = join(automationDir, "Requests");
    await mkdir(dir, { recursive: true });
    const tmp = join(dir, `.${id}.tmp`);
    await writeFile(tmp, JSON.stringify({ id, type, payload }));
    await rename(tmp, join(dir, `${id}.json`));
  } catch {
    // never disturb the agent session
  }
}

async function reportConversation(payload) {
  const conversationID = process.env.SOYEHT_CONVERSATION_ID;
  if (!conversationID) return;
  await writeAutomationRequest("report_agent_conversation", {
    sourceConversationID: conversationID,
    ...payload,
  });
}

async function reportAssistantPart(part, info) {
  await reportConversation({
    role: "assistant",
    text: part.text,
    nativeSessionID: part.sessionID,
    sourceEventID: part.id,
    model: info.providerID && info.modelID
      ? `${info.providerID}/${info.modelID}`
      : info.modelID,
    reasoningEffort: info.variant,
    variant: info.variant,
  });
}

async function report(state, message) {
  const conversationID = process.env.SOYEHT_CONVERSATION_ID;
  const automationDir = process.env.SOYEHT_AUTOMATION_DIR;
  if (!conversationID || !automationDir || !state) return;
  const payload = {
    state,
    sourceConversationID: conversationID,
    reportSource: SOURCE,
    seq: Date.now() * 1000 + Math.floor(Math.random() * 1000),
  };
  if (message) payload.message = String(message).slice(0, 200);
  const nonce = process.env.SOYEHT_LAUNCH_NONCE;
  if (nonce) payload.nonce = nonce;
  await writeAutomationRequest("report_agent_state", payload);
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
    "chat.message": async (input, output) => {
      lastBaseState = "working";
      const text = (output?.parts ?? [])
        .filter((part) => part?.type === "text" && !part.synthetic && !part.ignored)
        .map((part) => part.text ?? "")
        .join("\n")
        .trim();
      if (text && !text.startsWith("SOYEHT_AGENT_HANDOFF_")) {
        await reportConversation({
          role: "user",
          text,
          nativeSessionID: input?.sessionID,
          sourceEventID: output?.message?.id ?? input?.messageID,
          model: input?.model ? `${input.model.providerID}/${input.model.modelID}` : undefined,
          reasoningEffort: input?.variant,
          variant: input?.variant,
        });
      } else if (input?.sessionID) {
        await reportConversation({
          nativeSessionID: input.sessionID,
          model: input?.model ? `${input.model.providerID}/${input.model.modelID}` : undefined,
          reasoningEffort: input?.variant,
          variant: input?.variant,
        });
      }
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
          await reportConversation({
            nativeSessionID: properties?.info?.id ?? properties?.sessionID,
          });
          await publish();
          break;
        case "message.updated": {
          const info = properties?.info;
          if (info?.id) messageInfo.set(info.id, info);
          if (info?.role === "assistant") {
            const pendingPart = pendingTextParts.get(info.id);
            if (pendingPart) {
              pendingTextParts.delete(info.id);
              await reportAssistantPart(pendingPart, info);
            }
            await reportConversation({
              nativeSessionID: info.sessionID ?? properties?.sessionID,
              model: info.providerID && info.modelID
                ? `${info.providerID}/${info.modelID}`
                : info.modelID,
              reasoningEffort: info.variant,
              variant: info.variant,
            });
          }
          break;
        }
        case "message.part.updated": {
          const part = properties?.part;
          const info = messageInfo.get(part?.messageID);
          if (part?.type === "text" && !part.synthetic && !part.ignored) {
            if (info?.role === "assistant") {
              await reportAssistantPart(part, info);
            } else if (!info && part?.messageID) {
              // OpenCode usually emits message.updated first, but retain the
              // newest full text if event ordering changes between versions.
              pendingTextParts.set(part.messageID, part);
            }
          }
          break;
        }
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

    /// OpenCode and Kilo share the same typed plugin contract. Keep one
    /// structured-history implementation so event-order and filtering fixes
    /// cannot drift between the two adapters.
    static var opencodeStructuredPluginReporter: String {
        kiloPluginReporter
            .replacingOccurrences(
                of: "agent-state integration v6",
                with: "agent-state integration v12"
            )
            .replacingOccurrences(of: "hook:kilo", with: "hook:opencode")
    }

    /// Claude-compatible hook families use the same semantic event adapter.
    /// Only the state-report attribution fallback differs when an agent's
    /// config format cannot inject SOYEHT_REPORT_AGENT.
    static func claudeCompatibleStructuredReporter(agent: String) -> String {
        claudeCodexHookReporter.replacingOccurrences(
            of: "os.environ.get(\"SOYEHT_REPORT_AGENT\", \"agent\")",
            with: "os.environ.get(\"SOYEHT_REPORT_AGENT\", \"\(agent)\")"
        )
    }
}
