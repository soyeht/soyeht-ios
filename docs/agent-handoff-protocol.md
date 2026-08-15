# Soyeht Agent Handoff Protocol (SAHP) v1

SAHP preserves one logical Soyeht conversation while its pane changes coding
agents. It complements provider-native session resume; it does not replace MCP
or treat terminal rendering as an API.

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
5. Soyeht serializes only events after the target cursor in a JSON SAHP envelope
   and submits it after the target readiness handshake.
6. Once delivery succeeds, Soyeht advances the target cursor immediately. The
   update is merged into the latest store value so concurrent startup metadata
   is preserved.
7. Target hooks ignore the SAHP transport envelope as a new user message, so
   repeated switches do not duplicate history.

The legacy response field `transcriptLineCount` remains for automation
compatibility, but in SAHP it counts canonical message events, not terminal
lines. New clients should also inspect `historySource`, `importedEventCount`,
and `resumedNativeSession`.

## Adapter capabilities

Adapters declare capabilities instead of guessing unsupported flags:

- structured message capture
- native session resume
- model metadata
- reasoning-effort/variant metadata

Claude Code, Codex, and OpenCode support both structured capture and native
session resume. Structured-capture adapters without guessed resume flags are
also installed for Qwen, Antigravity, Pi, Droid, Kilo, Cursor Agent, Copilot,
Grok, Kimi, and Devin. Unknown agents, including Qoder until it has a supported
contract, fail closed.

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
- An empty canonical record produces no fabricated handoff prompt.
- Unknown adapters fail closed for native resume and metadata capabilities.
