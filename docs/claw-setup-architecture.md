# Claw Setup Architecture

Claw Setup must stay an intent-driven UI over a small domain model. The user
chooses where a Claw runs and how much performance they want. SwiftUI must not
own routing, resource math, or request construction.

## User Contract

- Primary controls are `Install on` and `Performance`.
- Performance is expressed as `Efficient`, `Standard`, `High`, or `Custom`.
- CPU, memory, and storage are advanced details.
- Technical availability messages are translated into user actions.
- The setup screen never teaches users about leases, warm pool, or protocol
  endpoints.

## Ownership Boundaries

- `ServerRegistry` is the source of server identity and display metadata.
- `ClawInstallTargetResolver` is the source of deploy routing.
- `ResourceOptions` from the engine is the source of live resource limits.
- `ClawSetupViewModel` is the source of setup state and creates the final
  `CreateInstanceRequest`.
- SwiftUI views render state and forward user intent only.

## Required Domain Types

Future implementation should keep these concepts explicit:

- `ClawPerformanceProfile`
  - `efficient`
  - `standard`
  - `high`
  - `custom`
- `ClawResourceSelection`
  - CPU cores
  - memory MB
  - storage GB
  - whether storage is server-managed
- `ClawSetupResourcePolicy`
  - maps profiles to resource selections
  - clamps selections to live `ResourceOptions`
  - marks manual edits as `custom`
  - decides whether `disk_gb` is sent
- `ClawSetupPresentation`
  - user-facing labels, subtitles, warnings, and primary action text

## Anti-Regression Rules

- `ClawSetupView` must not read `SessionStore.shared` directly.
- `ClawSetupView` must not create `ServerContext` or household endpoint URLs.
- CPU/RAM/storage defaults must not be duplicated in SwiftUI.
- The string `live limits unavailable` must not appear in user-facing UI.
- `disk_gb` must not be sent for Mac targets whose disk is server-managed.
- Household endpoint deploy and server-context deploy must share request
  construction.

## Testing Requirements

Before changing the setup screen, tests must cover:

- `Standard` applies the recommended defaults.
- `Efficient` lowers resource use without going below supported minimums.
- `High` raises resource use without exceeding live limits.
- Manual CPU, memory, or storage edits switch the profile to `Custom`.
- Missing live limits produce user-readable copy, not debug text.
- Mac managed-storage deploy omits `disk_gb`.
- Linux deploy includes `disk_gb`.
- Server-context and household-endpoint deploys produce equivalent
  `CreateInstanceRequest` values.
- Source-slice guards enforce the anti-regression rules above.

