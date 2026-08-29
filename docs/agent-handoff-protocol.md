# Soyeht Agent Handoff Protocol (SAHP) v1

SAHP preserves one logical Soyeht conversation while its pane changes coding
harnesses. It complements provider-native session resume; it does not replace MCP
or treat terminal rendering as an API.

## Terminology

- **Agent** means a named Soyeht pane identity such as `[ilia]`, `[marcia]`, or
  `[claude-input-audit]`. This is what users mean when they ask which agents are
  in a workspace, and it is what `list_agents` returns.
- **Pane** is the visual routing unit and user-facing identity. This matches the
  familiar tmux term (session → window → pane), although a Soyeht pane may host
  terminal or non-terminal content.
- **Harness** means the CLI/runtime wrapped around a model, such as Claude Code,
  Codex, OpenCode, Qwen Code, Antigravity, Pi, Droid, Kilo Code, Cursor, Copilot
  CLI, Grok, Kimi, Devin, or Qoder. Harnesses belong to the launch catalog, not
  the workspace agent directory.
- **Role** is an assignment such as planner, executor, reviewer, or aggregator.
- **Model/configuration** identifies the model, reasoning effort, launch profile,
  and flags used by a harness in one agent pane.

A pane may keep the same agent identity while switching harness, model, or role.
Messaging authorization is therefore pane-bound; harness catalog membership is
never an identity or authorization boundary.

Harnesses may also create their own internal subagents. Those are distinct from
named Soyeht agent panes. A request to message an existing named pane routes via
`list_agents` + `message_agent`; a request to create new internal subagents may
still use the harness's native delegation mechanism.

## Canonical record

The canonical record is an ordered, append-only list of user-visible messages:

- `sequence`, stable `id`, `role` (`user` or `assistant`), and `text`
- source agent and optional provider-native session/event identifiers
- optional model, reasoning-effort, and variant metadata
- creation time

System/developer instructions, hidden reasoning, tool calls/results, hook
payloads, terminal commands, status chrome, editor text, and terminal scrollback
are never canonical conversation events.

Each agent also has a session binding with its native session identifier,
metadata, and the last canonical sequence imported into that session.

## Switch transaction

1. Structured hooks/plugins finish recording the source agent's visible turn.
2. Soyeht advances the source session cursor through the current canonical tail.
3. Soyeht stops the source process and keeps the pane/conversation identity.
4. If the target has a supported native binding, Soyeht resumes that exact
   session. Otherwise it starts a new target session.
5. For Claude Code, Codex, and OpenCode, Soyeht submits only a short MCP
   bootstrap. The target calls `get_conversation_context`, follows
   `nextCursor` until `hasMore` is false, then calls
   `ack_conversation_context` with the final `throughSequence`. Other adapters
   receive only events after their cursor in a JSON SAHP envelope. Agents whose
   session is created by the first turn use prompt-bound readiness instead of
   waiting for a startup event that cannot exist yet.
6. Delivery is acknowledged only by a fresh hook report from the declared
   target agent. Soyeht retries swallowed TUI input, and long pasted prompts are
   submitted through the same Return-key path as interactive input.
7. MCP targets advance their cursor only after explicit acknowledgement of the
   final page. Envelope targets advance it after delivery succeeds. Updates are
   merged into the latest store value so concurrent startup metadata is
   preserved.
8. Target hooks ignore both transport bootstrap forms as new user messages, so
   repeated switches do not duplicate history.

Before an MCP-capable target starts, Soyeht repairs its managed MCP entry to
use the profile-aware launcher and pre-approves the two context transport
tools. If that repair fails, the switch sends the structured SAHP envelope
instead of an MCP bootstrap the target cannot satisfy. A source cursor advances
across locally authored events only while they are contiguous with its
acknowledged cursor; an unacknowledged MCP gap therefore survives a switch away
and can be retried.

Codex hook execution always follows Codex's native trust review. Soyeht does
not add `--dangerously-bypass-hook-trust`; a newly installed or changed hook
may therefore require one explicit approval in Codex. The managed Soyeht MCP
server is optional (`required = false`) so an unavailable launcher cannot
prevent unrelated Codex sessions from starting.

MCP pagination is event-based (20 messages by default, up to 50) and therefore
scales independently of terminal paste limits. A single message remains one
atomic event even when it is very large; future protocol versions may add
content chunks without changing semantic ordering.

The legacy response field `transcriptLineCount` remains for automation
compatibility, but in SAHP it counts canonical message events, not terminal
lines. New clients should also inspect `historySource`, `importedEventCount`,
and `resumedNativeSession`.

## Adapter capabilities

Adapters declare capabilities instead of guessing unsupported flags:

- structured message capture
- native session resume
- MCP context retrieval
- model metadata
- reasoning-effort/variant metadata

Claude Code, Codex, and OpenCode support both structured capture and native
session resume. Structured-capture adapters without guessed resume flags are
also installed for Qwen, Antigravity, Pi, Droid, Kilo, Cursor Agent, Copilot,
Grok, Kimi, and Devin. Unknown agents, including Qoder until it has a supported
contract, fail closed.

Provider-specific transcript adapters still normalize to the same record. For
example, Antigravity reads its documented `transcriptPath` and treats only
completed model `PLANNER_RESPONSE` content as assistant output; Copilot defers
its stop-time read briefly because its transcript appends the assistant message
after the stop hook returns. Devin is launched with a per-pane ATIF export and
imports only `source: agent` message steps. Hidden reasoning is never imported.

Adapter validation is independent from account/model availability. A provider
can prove hook installation, readiness, session binding, and SAHP receipt even
when its configured model later rejects the request; that failure must be
reported as an external provider block rather than a handoff failure.

## Safety and failure behavior

- There is no terminal/scrollback fallback.
- Legacy terminal transcripts are decoded only for snapshot compatibility,
  discarded, and never encoded again.
- Streaming events update by provider event id; exact adjacent finals are
  deduplicated.
- Events inherit missing session/model/effort metadata from the latest binding
  for their source agent.
- Agent attribution comes from the live Soyeht pane, not caller-supplied text.
- Panes export their declared agent identity. A global hook belonging to a
  different Claude-compatible CLI is inert and cannot acknowledge delivery or
  contaminate the canonical record.
- Agent panes disable terminal mouse reporting, preventing SGR mouse packets
  from appearing as random prompt text; shell panes retain mouse support.
- An empty canonical record produces no fabricated handoff prompt.
- Unknown adapters fail closed for native resume and metadata capabilities.
