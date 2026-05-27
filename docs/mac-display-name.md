# Mac display name — single source of truth

> If you are adding a SwiftUI view that shows a paired Mac to the user,
> **read this file first**. The rules below are enforced by tests in
> `TerminalApp/SoyehtTests/PairedMacAliasTests.swift` — if you break them,
> those tests will fail.

## What the user sees

A `PairedMac` has two name-like fields with distinct roles:

| Field        | Source                      | Purpose                                |
| ------------ | --------------------------- | -------------------------------------- |
| `name`       | hostname sent by the engine | diagnostics, logs, naming suggestion   |
| `alias`      | user-typed in `MacAliasView`| user-facing display (canonical)        |

The user picks an alias on first pairing (mandatory — no skip button) and
can rename it later in **Settings → Paired Macs**.

## The three rules

### Rule 1 — Always render `mac.displayName`

```swift
// CORRECT
Text(mac.displayName)

// WRONG — never read `mac.name` in a SwiftUI view
Text(mac.name)
```

`PairedMac.displayName` returns the alias when set, falling back to the
hostname while the user has not chosen one. The only place `mac.name`
appears in the UI is the **pre-fill value of the naming field**, and that
is already handled inside `MacAliasView.init`.

### Rule 2 — Always mutate alias through `PairedMacsStore.setAlias`

```swift
// CORRECT
switch PairedMacsStore.shared.setAlias(macID: mac.macID, alias: input) {
case .success: ...
case .duplicate(let conflictingMacID): show duplicate-name error
case .invalid(let reason): show validation error
case .unknownMac: dismiss
}

// WRONG — never assign `alias` directly
store.macs[idx].alias = "..."   // bypasses validation + dedup
```

`setAlias` is the single funnel that enforces:

1. trim + non-empty + length ≤ `MacAliasRules.maxLength` + no forbidden
   characters (validation lives in `MacAliasValidator.validate`);
2. uniqueness across **all** paired Macs in the same household
   (case-insensitive comparison).

### Rule 3 — For `PairedServer` engine-kind rows, use `displayName(forServer:)`

When you render a row from `SessionStore.pairedServers`, do **not** call
`server.displayName` directly. The single helper is:

```swift
Text(PairedMacsStore.shared.displayName(forServer: server))
```

It looks up the `PairedMac` that backs an engine-kind server (matching
`server.host == mac.lastHost`) and returns that Mac's `displayName`. It
falls through to `server.displayName` for non-engine kinds and for
servers with no matching Mac.

## Where the naming UI lives

- **First-time naming**: presented automatically by `InstanceListView` as a
  `fullScreenCover` whenever `PairedMacsStoreObservable.shared.macs` contains
  a Mac with `needsAlias == true`. The cover wraps `MacAliasView` with
  `.interactiveDismissDisabled()` so the user cannot swipe to skip.

- **Rename**: presented from `PairedMacsListView` as a regular
  dismissable `.sheet` reusing the same `MacAliasView`.

## When you need to extend this

- Adding a new screen that shows a Mac: just read `mac.displayName`.
- Adding new validation: extend `MacAliasValidator` and `MacAliasError`,
  add a test, update the error switch in `MacAliasView.submit`. Do not
  scatter validation across views.
- Adding a new duplicate-detection scope (e.g. across households): extend
  the check inside `PairedMacsStore.setAlias` — single mutator.

## Files

| File                                                          | Role                          |
| ------------------------------------------------------------- | ----------------------------- |
| `TerminalApp/Soyeht/Pairing/PairedMacsStore.swift`            | Data + mutator + lookups      |
| `TerminalApp/Soyeht/Pairing/MacAliasView.swift`               | Naming + rename UI            |
| `TerminalApp/Soyeht/Pairing/MacHomeRow.swift`                 | Home-list row consumer        |
| `TerminalApp/Soyeht/InstanceListView.swift`                   | Mandatory cover presentation  |
| `TerminalApp/Soyeht/Settings/PairedMacsListView.swift`        | Rename presentation           |
| `TerminalApp/SoyehtTests/PairedMacAliasTests.swift`           | Contract tests                |
