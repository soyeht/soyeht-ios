# TODO / Open Issues

Index of open tech-debt items and follow-ups tracked as markdown in this
repo (instead of a GitHub issue tracker) so they're visible to anyone
working in the folder and picked up automatically by Claude Code.

## iOS

- [`docs/issue-server-scoped-api-client.md`](docs/issue-server-scoped-api-client.md)
  — Refactor `SoyehtAPIClient` so per-instance calls take an explicit
  `(server, token)` context instead of reading `SessionStore.activeServerId`
  globally. Blocks cleanly supporting multi-server instance lists.
