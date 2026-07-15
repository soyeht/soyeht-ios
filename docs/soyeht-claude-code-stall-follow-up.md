# Soyeht Claude Code Stall Follow-Up

## Summary

We have observed repeated cases where a Claude Code agent appears stalled or
visually frozen while running inside a Soyeht pane during a long autonomous
goal. This should be treated as a project reliability issue for Soyeht's agent
pane lifecycle and long-running agent orchestration.

This document intentionally avoids real local paths, machine names, session IDs,
private workspace names, and user infrastructure identifiers. Use local logs for
exact incident details when investigating.

## Observed Pattern

In one recent incident:

- A long-running Claude Code `/goal` was launched from a Soyeht pane.
- The pane remained visible with stale goal text and a "crunched for ..." status.
- Soyeht initially reported the pane as live but idle.
- A few minutes later, Soyeht automation no longer resolved the pane's
  conversation ID.
- The Claude Code session history still existed locally and was resumable with
  `claude --resume <session-id>`.

The user-facing failure mode is confusing: the pane looks like the agent may
still be working, while the live Soyeht conversation may already be detached,
dead, or no longer addressable.

In a later recurrence, the failure mode looked different:

- Soyeht still listed the pane as live and able to receive messages.
- The pane was visually present and still showed an active autonomous goal.
- The visible terminal UI indicated the agent was working on the next task.
- The user reported being unable to type into that pane.
- The pane metadata did not clearly distinguish "actively working and input is
  queued/blocked" from "terminal input path is wedged".

This second mode suggests the investigation should cover both detached panes
and panes that remain addressable but stop accepting normal user input.

## Why This Matters

Long Soyeht-driven agent goals often coordinate several reviewers or subagents.
If a leader pane silently detaches or stops resolving, the work can appear
blocked even though the Claude Code session can be recovered from local history.

This creates operational risk:

- The user may wait on a pane that is no longer progressing.
- Reviewers may assume a leader is still active.
- Follow-up work may fork into a new pane without clear continuity.
- Important recovery handles, such as the Claude Code session ID, may not be
  obvious from the Soyeht UI.

## Hypotheses

Likely causes to investigate:

- Soyeht pane status tracking can lose a live conversation while the terminal
  view still displays stale content.
- Claude Code can stop after hook or goal-status feedback without a clear
  terminal state transition in Soyeht.
- Very long contexts, `/goal`, and subagent/workflow activity may increase the
  chance of apparent stalls.
- Soyeht may preserve a visual terminal buffer after the underlying Claude Code
  process exits or detaches.
- Soyeht or the embedded agent TUI may enter a state where the process is still
  live and working, but normal pane text entry is queued, blocked, or not routed
  to the expected input buffer.
- The pane status vocabulary may be too coarse for long-running AI sessions:
  `active`, `idle`, `dead`, and `not_live` do not clearly distinguish "still
  reasoning", "waiting for input", "input temporarily blocked", "detached but
  resumable", and "process gone".

## Data To Capture Next Time

When this happens again, capture the following before opening a replacement
pane:

- Soyeht `capture_pane` visible text.
- Soyeht `get_pane_status` for the target pane.
- Whether `list_agents` still shows the handle and conversation ID.
- Whether the visible pane shows an active goal, queued-message prompt, or other
  agent TUI state while typing is blocked.
- Local process state for Claude Code and related child processes.
- The latest Claude Code history entry for the project.
- Whether `claude --resume <session-id>` can recover the session.
- Whether the same Soyeht conversation ID later becomes unresolvable.

Do not paste private session IDs, local usernames, machine names, or absolute
local paths into public issues or docs. Keep raw incident data in local notes or
private logs.

## Possible Product Fixes

Potential improvements:

- Add an agent heartbeat visible in Soyeht for long-running Claude Code panes.
- Surface a "last output time" and "last process heartbeat" separately.
- Detect and label "detached but resumable" when Claude Code history exists but
  the pane conversation no longer resolves.
- Show the Claude Code resume command in the pane metadata when available.
- Add a Soyeht command to recover or reopen a pane from the most recent Claude
  Code session for that workspace.
- Improve idle/dead/not-live status transitions so stale terminal text is not
  mistaken for active reasoning.

## Recovery Playbook

If a pane appears stalled:

1. Query Soyeht status and capture the visible pane text.
2. Check Claude Code history for the relevant project and goal text.
3. Resume from the matching Claude Code session:

   ```bash
   cd <project-root>
   claude --resume <session-id>
   ```

4. Paste a short continuity prompt that names the goal, the last completed item,
   the current branch, and any hard stops.
5. Keep the old pane around until the resumed session confirms continuity.

## Open Question

Should Soyeht own this as a pane lifecycle bug, a Claude Code integration
recovery feature, or both?
