# Retired server inventory read-flip runbook

The experimental version-two server inventory path is retired. The shipped
storage authority is the v1 `ServerStore`, accessed through
`ServerInventoryWriter` and `ServerRegistry`.

There is no operator read flip for current builds. Do not add a hidden mirror,
runtime flag, or alternate projection path under this runbook. If a replacement
storage model is needed later, it should arrive as a new design with fresh
migration, dry-run, rollback, and live-evidence requirements.
