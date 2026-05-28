# Resource Management Architecture

Soyeht is self-hosted: one human owns the host and the Claws competing for
resources. This is a cooperative scheduler, not a multi-tenant datacenter.
The architecture still needs hard boundaries because regressions in capacity
accounting make the product feel broken.

This document defines the trunk: module ownership, state, database shape,
policy contracts, host adapters, recovery behavior, and extension points.

## Module Shape

```
SwiftUI / iOS
  ClawPerformanceProfile (intent)
  ClawSetupResourcePolicy (UI-side projection only)
        |
        v
Soyeht API
  POST /instances { claw, profile, optional advanced resources }
        |
        v
server-rs
  ResourceManager
    - reads leases and tier config
    - reads pressure snapshot
    - asks AdmissionPolicy for a decision
    - writes leases through InstanceDb
    - calls HostRuntimeAdapter for mechanisms
        |
        +-- AdmissionPolicy (pure)
        +-- EvictionPolicy (pure)
        +-- CapacityProjection (from resource_leases)
        +-- PressureSnapshot (observed, not authoritative)
        |
        +-- FirecrackerHostAdapter
        |     cgroup v2, Firecracker API, rootfs resize, snapshots
        |
        +-- VirtualizationHostAdapter
              VZ cpuCount/memorySize, macOS guest disk, save state
```

Responsibility split:

- `ResourceManager` coordinates; it does not contain scheduling math.
- `AdmissionPolicy` and `EvictionPolicy` are pure functions.
- `HostRuntimeAdapter` executes decisions; it does not decide them.
- `InstanceDb` owns durable state.
- `resource_leases` are the single source of truth for allocated capacity.
- Pressure is advisory input, never allocation truth.

## User-Facing Profiles

The primary UI exposes four profile states:

```swift
enum ClawPerformanceProfile: String, Codable, Sendable {
    case efficient
    case standard
    case high
    case custom
}
```

Profiles map to a tier row. The names are product intent; the values are host
policy inputs.

```rust
struct ResourceTier {
    id: String,                 // "efficient", "standard", "high"
    version: u32,
    enabled: bool,
    cpu_weight: u16,            // cgroup cpu.weight on Linux
    io_weight: u16,             // cgroup io.weight on Linux
    boot_floor_cpu: u32,
    boot_floor_ram_mb: u32,
    target_cpu: u32,
    target_ram_mb: u32,
    burst_cpu: u32,
    burst_ram_mb: u32,
    initial_disk_gb: u32,
    auto_grow_limit_gb: Option<u32>,
    updated_at: i64,
}
```

`boot_floor` is not a customer guarantee. It is the minimum useful shape for
the Claw. `target` is the normal allocation. `burst` is the ceiling when the
host is idle.

## SQLite Schema

Existing table, kept authoritative:

```sql
CREATE TABLE resource_leases (
    id TEXT PRIMARY KEY,
    owner_type TEXT NOT NULL CHECK (owner_type IN ('instance', 'warm_pool')),
    owner_id TEXT NOT NULL,
    lease_kind TEXT NOT NULL CHECK (lease_kind IN ('runtime', 'storage')),
    cpu_cores INTEGER NOT NULL CHECK (cpu_cores >= 0),
    ram_mb INTEGER NOT NULL CHECK (ram_mb >= 0),
    disk_gb INTEGER NOT NULL DEFAULT 0 CHECK (disk_gb >= 0),
    acquired_at INTEGER NOT NULL,
    expires_at INTEGER,
    released_at INTEGER
);
```

Non-destructive migration for profile and tier state:

```sql
ALTER TABLE instances ADD COLUMN performance_profile TEXT NOT NULL DEFAULT 'standard';
ALTER TABLE instances ADD COLUMN performance_base_profile TEXT;
ALTER TABLE instances ADD COLUMN performance_tier_version INTEGER;
ALTER TABLE instances ADD COLUMN cpu_weight INTEGER;
ALTER TABLE instances ADD COLUMN io_weight INTEGER;
ALTER TABLE instances ADD COLUMN burst_cpu_cores INTEGER;
ALTER TABLE instances ADD COLUMN burst_ram_mb INTEGER;
ALTER TABLE instances ADD COLUMN storage_limit_gb INTEGER;

CREATE TABLE resource_tiers (
    id TEXT PRIMARY KEY,
    cpu_weight INTEGER NOT NULL,
    io_weight INTEGER NOT NULL,
    boot_floor_cpu INTEGER NOT NULL,
    boot_floor_ram_mb INTEGER NOT NULL,
    target_cpu INTEGER NOT NULL,
    target_ram_mb INTEGER NOT NULL,
    burst_cpu INTEGER NOT NULL,
    burst_ram_mb INTEGER NOT NULL,
    initial_disk_gb INTEGER NOT NULL,
    auto_grow_limit_gb INTEGER,
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    version INTEGER NOT NULL DEFAULT 1,
    updated_at INTEGER NOT NULL
);

CREATE TABLE pressure_log (
    id TEXT PRIMARY KEY,
    captured_at INTEGER NOT NULL,
    host_kind TEXT NOT NULL CHECK (host_kind IN ('linux', 'macos')),
    cpu_pressure_some REAL,
    cpu_pressure_full REAL,
    memory_pressure_some REAL,
    memory_pressure_full REAL,
    io_pressure_some REAL,
    io_pressure_full REAL,
    memory_pressure_state TEXT,
    thermal_state TEXT
);

CREATE TABLE resource_events (
    id TEXT PRIMARY KEY,
    request_id TEXT NOT NULL,
    instance_id TEXT,
    event_type TEXT NOT NULL,
    from_state TEXT,
    to_state TEXT,
    actor TEXT NOT NULL,
    reason_code TEXT,
    user_action TEXT,
    detail_json TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
```

`pressure_log` is diagnostic history. It is not used to reconstruct allocation.
Recovery reconstructs allocation from `instances`, VM liveness, and
`resource_leases`.
`resource_events` is the durable audit trail for admission decisions and VM
lifecycle transitions.

## Tier Configuration

Seed tiers are versioned data, not scattered constants.

```toml
[[tier]]
id = "efficient"
cpu_weight = 50
io_weight = 50
boot_floor_cpu = 1
boot_floor_ram_mb = 1024
target_cpu = 1
target_ram_mb = 1536
burst_cpu = 2
burst_ram_mb = 2048
initial_disk_gb = 10
auto_grow_limit_gb = 50

[[tier]]
id = "standard"
cpu_weight = 100
io_weight = 100
boot_floor_cpu = 1
boot_floor_ram_mb = 1024
target_cpu = 2
target_ram_mb = 2048
burst_cpu = 4
burst_ram_mb = 4096
initial_disk_gb = 10
auto_grow_limit_gb = 50

[[tier]]
id = "high"
cpu_weight = 200
io_weight = 200
boot_floor_cpu = 2
boot_floor_ram_mb = 2048
target_cpu = 4
target_ram_mb = 4096
burst_cpu = 6
burst_ram_mb = 8192
initial_disk_gb = 20
auto_grow_limit_gb = 100
```

The database receives these rows at startup if missing. Changes are explicit
migrations, not silent edits to Rust constants.

## Tier Reload

`resource_tiers.toml` is loaded at startup and on `SIGHUP`.

Reload rules:

- New tier id: inserted with `enabled = 1`.
- Existing tier id: row is updated and `version` increments.
- Missing tier id from TOML: row is marked `enabled = 0`; hard delete is not
  used.
- Disabled tier with active instances: active instances keep their persisted
  `performance_profile`, `performance_tier_version`, `cpu_weight`, `io_weight`,
  `burst_cpu_cores`, `burst_ram_mb`, and `storage_limit_gb` snapshot.
- Active instances are not automatically re-applied when a tier changes.
- New instances use the currently enabled tier row.
- User-initiated performance changes call `AdmissionPolicy::admit` and then
  `HostRuntimeAdapter::apply_tier`.
- Requests for disabled tiers are rejected with `RejectReason::TierDisabled`.

This makes tier reload deterministic: configuration changes affect new work,
and active work changes only through an explicit user or system event.

## Core Types

All fields below are public within the resource-management module boundary.
Derives are omitted from the sketches.

```rust
struct CapacityProjection {
    host_cpu: u32,
    host_ram_mb: u64,
    host_disk_gb: u64,
    cpu_budget: i64,
    ram_budget: i64,
    allocated_cpu: i64,
    allocated_ram: i64,
    allocated_disk: i64,
    available_cpu: i64,
    available_ram: i64,
    available_disk: i64,
    macos_slots_used: i64,
    macos_slots_total: i64,
}

struct PressureSnapshot {
    host_kind: HostKind,
    cpu: PressureLevel,
    memory: PressureLevel,
    io: PressureLevel,
    thermal: ThermalLevel,
}

enum PressureLevel {
    Unknown,
    Healthy,
    Elevated,
    Critical,
}

enum HostKind {
    Linux,
    MacOS,
}

enum ThermalLevel {
    Unknown,
    Nominal,
    Fair,
    Serious,
    Critical,
}

struct CreateInstanceRequest {
    request_id: String,
    actor: String,
    claw_type: String,
    instance_name: String,
    profile: ClawPerformanceProfile,
    base_profile: Option<ClawPerformanceProfile>,
    custom_resources: Option<CustomResourceRequest>,
    guest_os: String,
    target_host_id: String,
}

struct CustomResourceRequest {
    cpu_cores: u32,
    ram_mb: u32,
    storage_gb: Option<u32>,
}

struct RuntimeLeaseRequest {
    owner_type: String,     // "instance" or "warm_pool"
    owner_id: String,
    cpu_cores: i64,
    ram_mb: i64,
    expires_at: Option<i64>,
}

struct StorageLeaseRequest {
    owner_type: String,
    owner_id: String,
    disk_gb: i64,
    expires_at: Option<i64>,
}

struct TierApplication {
    profile: ClawPerformanceProfile,
    base_profile: Option<ClawPerformanceProfile>,
    tier_version: Option<u32>,
    cpu_cores: u32,
    ram_mb: u32,
    storage_gb: Option<u32>,
    storage_limit_gb: Option<u32>,
    cpu_weight: u16,
    io_weight: u16,
    memory_high_mb: Option<u32>,
    memory_max_mb: Option<u32>,
}

struct WarmPoolEviction {
    owner_id: String,
    claw_type: String,
    reason: WarmPoolEvictionReason,
    release_runtime_lease: bool,
}

enum WarmPoolEvictionReason {
    ClawUnavailable,
    LeastRecentlyUsed,
    HighestResourceCost,
    CheapestRefill,
    TieBreak,
}

struct WarmPoolSlotView {
    owner_id: String,
    claw_type: String,
    state: WarmPoolSlotState,
    cpu_cores: i64,
    ram_mb: i64,
    last_used_at: Option<i64>,
    refill_cost: RefillCost,
}

enum WarmPoolSlotState {
    Empty,
    Filling,
    Warm,
}

struct RefillCost {
    estimated_seconds: u32,
    estimated_io_mb: u32,
}

struct InstanceRuntimeView {
    instance_id: String,
    claw_type: String,
    state: VmState,
    profile: ClawPerformanceProfile,
    cpu_cores: i64,
    ram_mb: i64,
    disk_gb: i64,
    host_kind: HostKind,
}

struct LiveInstance {
    instance_id: String,
    pid: Option<u32>,
    state: VmState,
    host_kind: HostKind,
    started_at: Option<i64>,
}

struct ClawUsageEvent {
    claw_type: String,
    last_started_at: Option<i64>,
    last_claimed_warm_slot_at: Option<i64>,
    launch_count_30d: u32,
}

struct SnapshotRef {
    instance_id: String,
    path: String,
    created_at: i64,
    runtime_fingerprint: String,
}

enum RejectReason {
    InsufficientCpu { requested: u32, available: i64 },
    InsufficientRam { requested_mb: u32, available_mb: i64 },
    InsufficientDisk { requested_gb: u32, available_gb: i64 },
    HostPressureCritical { resource: PressureResource },
    MacSlotLimitReached { used: i64, total: i64 },
    TierDisabled { tier_id: String },
    UnsupportedOnHost { op: RuntimeOperation, host_kind: HostKind },
    InvalidCustomResources { field: String, min: u32, requested: u32 },
}

enum UserAction {
    UseStandard,
    ChooseAnotherServer,
    StopAnotherApp,
    WaitForPressureToDrop,
    PrepareMac,
    Retry,
}

enum PressureResource {
    Cpu,
    Memory,
    Io,
    Thermal,
}

enum VmState {
    Requested,
    Admitted,
    Provisioning,
    Starting,
    Active,
    Suspended,
    Restarting,
    Stopping,
    Stopped,
    Failed,
}

enum RuntimeOperation {
    ApplyTier,
    ResizeStorage,
    Suspend,
    Resume,
    Snapshot,
    EvictWarmPool,
    LiveInstances,
}

enum RuntimeMechanism {
    FirecrackerIpc,
    FirecrackerCgroup,
    FirecrackerBalloon,
    FirecrackerSnapshot,
    LinuxRootfsResize,
    VirtualizationFramework,
    MacMemoryPressure,
    MacSaveState,
}

struct ErrorDetail {
    code: String,
    message: String,
    retryable: bool,
}

enum RuntimeError {
    UnsupportedOnHost { op: RuntimeOperation, host_kind: HostKind },
    MechanismFailed { kind: RuntimeMechanism, detail: ErrorDetail },
    InstanceNotFound { instance_id: String },
    InstanceNotInExpectedState { instance_id: String, current: VmState, expected: Vec<VmState> },
    IpcUnavailable { endpoint: String, detail: ErrorDetail },
    IpcProtocolMismatch { expected_version: u16, actual_version: u16 },
    Timeout { op: RuntimeOperation, timeout_ms: u64 },
    PermissionDenied { op: RuntimeOperation, mechanism: RuntimeMechanism },
}
```

## Policy Contracts

Admission is pure:

```rust
trait AdmissionPolicy {
    fn admit(&self, input: AdmissionInput<'_>) -> AdmissionDecision;
}

struct AdmissionInput<'a> {
    projection: &'a CapacityProjection,
    pressure: &'a PressureSnapshot,
    request: &'a CreateInstanceRequest,
    tier: &'a EffectiveTier,
    active_instances: &'a [InstanceRuntimeView],
    warm_pool: &'a [WarmPoolSlotView],
}

enum AdmissionDecision {
    Admit {
        runtime_lease: RuntimeLeaseRequest,
        storage_lease: StorageLeaseRequest,
        tier_application: TierApplication,
    },
    AdmitAfterEvictingWarmPool {
        evictions: Vec<WarmPoolEviction>,
        runtime_lease: RuntimeLeaseRequest,
        storage_lease: StorageLeaseRequest,
        tier_application: TierApplication,
    },
    Reject {
        reason: RejectReason,
        user_action: UserAction,
    },
}
```

`EffectiveTier` is either a row from `resource_tiers` or a custom tier derived
from the request:

```rust
enum EffectiveTier {
    Named(ResourceTier),
    Custom {
        base_profile: ClawPerformanceProfile,
        base_tier_version: Option<u32>,
        cpu_weight: u16,
        io_weight: u16,
        boot_floor_cpu: u32,
        boot_floor_ram_mb: u32,
        requested_cpu: u32,
        requested_ram_mb: u32,
        requested_storage_gb: Option<u32>,
        storage_limit_gb: Option<u32>,
    },
}
```

Custom resolution rules:

- `base_profile` defaults to `standard` when the request omits it.
- `cpu_weight` and `io_weight` are copied from the base profile.
- `requested_cpu` and `requested_ram_mb` are clamped above the base
  `boot_floor`.
- `requested_storage_gb` is ignored for Mac managed-storage targets.
- Custom can exceed named tier burst values only up to live `ResourceOptions`
  and host admission limits.
- Custom never bypasses pressure checks, storage reserve, macOS slot limits, or
  warm pool eviction rules.

Eviction is pure:

```rust
trait EvictionPolicy {
    fn plan(&self, input: EvictionInput<'_>) -> Vec<WarmPoolEviction>;
}

struct EvictionInput<'a> {
    required_cpu: i64,
    required_ram_mb: i64,
    installed_claws: &'a [String],
    warm_pool_slots: &'a [WarmPoolSlotView],
    recent_usage: &'a [ClawUsageEvent],
}
```

Warm pool eviction order is deterministic:

1. Slot for uninstalled or unavailable Claw.
2. Least recently used Claw type.
3. Highest CPU/RAM slot.
4. Cheapest refill cost.
5. Lexicographic owner id as final tiebreaker.

## IPC Boundary

`server-rs` keeps the current local vmrunner IPC transport. Resource-management
messages use a versioned envelope so both sides can reject incompatible shapes
without string parsing:

```rust
struct RuntimeIpcEnvelope<T> {
    protocol_version: u16,
    request_id: String,
    op: RuntimeOperation,
    payload: T,
}
```

Rules:

- `protocol_version` increments only for breaking message-shape changes.
- Unknown `op` returns `RuntimeError::IpcProtocolMismatch`.
- Transport failure returns `RuntimeError::IpcUnavailable`.
- Handler timeouts return `RuntimeError::Timeout`.
- `pressure_snapshot()` is local to `server-rs`: Linux reads host pressure
  files; macOS reads host memory and thermal state.
- `live_instances()` crosses IPC because vmrunner owns runtime process state.
- Linux adapters may cross-check `/proc` for diagnostics, but IPC is the API
  contract.

## Host Runtime Adapter

Mechanism is behind one interface:

```rust
#[async_trait]
trait HostRuntimeAdapter {
    fn host_kind(&self) -> HostKind;
    fn pressure_snapshot(&self) -> PressureSnapshot;
    async fn apply_tier(&self, instance_id: &str, tier: &TierApplication) -> Result<(), RuntimeError>;
    async fn resize_storage(&self, instance_id: &str, new_limit_gb: u32) -> Result<(), RuntimeError>;
    async fn suspend(&self, instance_id: &str) -> Result<(), RuntimeError>;
    async fn resume(&self, instance_id: &str) -> Result<(), RuntimeError>;
    async fn snapshot(&self, instance_id: &str) -> Result<SnapshotRef, RuntimeError>;
    async fn evict_warm_pool(&self, eviction: &WarmPoolEviction) -> Result<(), RuntimeError>;
    async fn live_instances(&self) -> Result<Vec<LiveInstance>, RuntimeError>;
}
```

Linux implementation:

- Creates a cgroup v2 group per instance.
- Moves Firecracker process and child threads into the cgroup.
- Applies `cpu.weight`, `memory.high`, safety `memory.max`, `io.weight`, and
  background `io.max`.
- Uses Firecracker APIs for VM lifecycle.
- Uses rootfs expansion plus filesystem resize for storage growth.

macOS implementation:

- Applies `cpuCount` and `memorySize` only at launch/restart.
- Treats storage resize as unsupported until validated separately.
- Reports macOS memory pressure and thermal state.
- Limits concurrent disk-heavy operations through ResourceManager.
- Keeps warm pool disabled or bounded by explicit policy.

## VM State Machine

Durable states:

```
Requested
  -> Admitted
  -> Provisioning
  -> Starting
  -> Active
  -> Suspended
  -> Restarting
  -> Stopping
  -> Stopped
  -> Failed
```

Events:

- `CreateRequested`
- `AdmissionGranted`
- `AdmissionRejected`
- `ProvisioningStarted`
- `ProvisioningCompleted`
- `StartCompleted`
- `HeartbeatLost`
- `RestartRequested`
- `RestartCompleted`
- `StopRequested`
- `StopCompleted`
- `RuntimeFailed`
- `StorageResizeRequested`
- `StorageResizeCompleted`

Transition table:

| Event | From | To | Notes |
| --- | --- | --- | --- |
| `CreateRequested` | none | `Requested` | Creates request id and audit row before admission. |
| `AdmissionGranted` | `Requested` | `Admitted` | Runtime/storage lease requests are written in the same transaction. |
| `AdmissionRejected` | `Requested` | `Failed` | No runtime or storage lease is created; rejection is audited. |
| `ProvisioningStarted` | `Admitted` | `Provisioning` | Mechanism work begins after leases exist. |
| `ProvisioningCompleted` | `Provisioning` | `Starting` | Guest image/rootfs is ready; VM launch can begin. |
| `StartCompleted` | `Starting`, `Restarting` | `Active` | Runtime lease must exist before this transition. |
| `HeartbeatLost` | `Active` | `Restarting` | Recovery attempts restart before declaring failure. |
| `RestartRequested` | `Active`, `Suspended`, `Stopped`, `Failed` | `Restarting` | User or recovery initiated. |
| `RestartCompleted` | `Restarting` | `Active` | Recreates runtime lease if sweep released it. |
| `StopRequested` | `Requested`, `Admitted`, `Provisioning`, `Starting`, `Active`, `Suspended`, `Restarting`, `Failed` | `Stopping` | Idempotent; storage lease remains. |
| `StopCompleted` | `Stopping` | `Stopped` | Runtime lease is released. |
| `RuntimeFailed` | `Provisioning`, `Starting`, `Active`, `Restarting`, `Stopping` | `Failed` | Runtime lease is released unless recovery immediately restarts. |
| `StorageResizeRequested` | `Active`, `Stopped`, `Suspended` | unchanged | Storage lease is expanded before filesystem work. |
| `StorageResizeCompleted` | `Active`, `Stopped`, `Suspended` | unchanged | Emits audit event with old/new size. |

Persistence rules:

- `instances.status` stores the durable lifecycle state.
- `resource_leases` stores active runtime and storage allocation.
- Runtime leases exist only while a VM is intended to consume CPU/RAM.
- Storage leases remain until the instance is deleted.
- Warm pool leases are runtime-only and always evictable.

## Recovery

Startup recovery runs in this order:

1. Read `instances` and active `resource_leases`.
2. Ask `HostRuntimeAdapter.live_instances()` for real VM state.
3. Mark missing active VMs as stopped and release their runtime leases.
4. Auto-restart instances whose desired state is running.
5. After each successful restart, recreate the runtime lease if reconciliation
   released it.
6. Release warm pool leases whose slot no longer exists or whose Claw is no
   longer installed.
7. Recompute `CapacityProjection` from leases only.

No recovery path reconstructs capacity from pressure metrics.

## Audit Surface

Every state-machine event is persisted to `resource_events` and emitted through
structured tracing with the same `request_id`. Instance-bound events are also
mirrored to the existing instance event stream consumed by app status UI.

Retention:

- `resource_events`: 90 days.
- Structured logs: service log retention.
- `pressure_log`: 7 days because it is diagnostic sampling, not allocation
  history.

Cleanup runs at server startup and once per day while the daemon is running.

Production question answered by audit:

> Why was this deploy rejected at 14:32?

Query `resource_events` by `request_id`, `instance_id`, `actor`, or
`created_at`; `AdmissionRejected` rows carry `reason_code`, `user_action`, and
the serialized `AdmissionInput` summary in `detail_json`.

| Event | Persisted | Emitted | Detail |
| --- | --- | --- | --- |
| `CreateRequested` | `resource_events` | tracing | actor, claw, profile, target host |
| `AdmissionGranted` | `resource_events`, instance events | tracing, metric | lease sizes and tier application |
| `AdmissionRejected` | `resource_events` | tracing, metric | `RejectReason`, `UserAction`, projection summary |
| `ProvisioningStarted` | `resource_events`, instance events | tracing | mechanism and artifact ids |
| `ProvisioningCompleted` | `resource_events`, instance events | tracing, metric | duration and artifact fingerprint |
| `StartCompleted` | `resource_events`, instance events | tracing, metric | runtime pid/live id |
| `HeartbeatLost` | `resource_events`, instance events | tracing, metric | last heartbeat timestamp |
| `RestartRequested` | `resource_events`, instance events | tracing | requester and reason |
| `RestartCompleted` | `resource_events`, instance events | tracing, metric | lease restoration flag |
| `StopRequested` | `resource_events`, instance events | tracing | requester and reason |
| `StopCompleted` | `resource_events`, instance events | tracing, metric | runtime lease release id |
| `RuntimeFailed` | `resource_events`, instance events | tracing, metric | `RuntimeError` variant |
| `StorageResizeRequested` | `resource_events`, instance events | tracing | old/new storage lease size |
| `StorageResizeCompleted` | `resource_events`, instance events | tracing, metric | filesystem result and final size |

## Extension Points

| Feature | Extension point | Rule |
| --- | --- | --- |
| UI presets | `ClawPerformanceProfile` + `resource_tiers` | UI sends intent; server resolves tier. |
| CPU weights | `HostRuntimeAdapter.apply_tier` | Policy chooses tier; adapter writes cgroup/VZ config. |
| Warm pool preemption | `EvictionPolicy::plan` | User deploy beats cache. |
| Firecracker balloon | `HostRuntimeAdapter.apply_tier` | Adapter mechanism; policy remains pure. |
| Storage auto-grow | `resize_storage` + storage lease update | Lease updates before filesystem growth. |
| Mac conservative mode | `AdmissionPolicy` host branch | Same policy input; different host constraints. |
| Snapshots | `snapshot/suspend/resume` | Used for resume speed, not as first resize primitive. |
| IO throttling | `apply_tier` | Linux cgroup only; Mac uses concurrency limits. |

## Invariants

- `resource_leases` are the single source of truth for allocated capacity.
- Tier rows are config; instance rows carry the applied tier snapshot.
- `PressureSnapshot` is advisory and never authoritative.
- `pressure_log` is diagnostic and never used for recovery allocation.
- Admission and eviction policy are pure and unit-testable.
- Host adapters execute decisions and never choose policy.
- IPC messages crossing `server-rs` and vmrunner are versioned.
- Warm pool cannot block explicit user deploy when an eviction can free enough
  capacity.
- Storage lease is written before storage growth starts.
- Runtime lease is written before VM start and released after VM stop.
- Mac custom `disk_gb` is not accepted while Mac disk is server-managed.
- UI profiles are product intent; backend tiers are scheduling policy.
- Custom profiles use the same admission path as named profiles.
- Every admission rejection leaves a `resource_events` audit row.

## Trade-Offs

- CPU credits are excluded. Single-owner self-hosted scheduling needs weights,
  not billing fairness.
- RAM uses smooth degradation first. Hard caps exist only as safety nets.
- Mac hosts prioritize quality over density.
- Linux hosts use stronger resource controls because cgroup v2 gives reliable
  mechanisms.
- Snapshots are not the primary resize primitive because saved state
  compatibility depends on VM configuration.
