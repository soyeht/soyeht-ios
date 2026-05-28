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
    auto_grow_limit_gb INTEGER
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
```

`pressure_log` is diagnostic history. It is not used to reconstruct allocation.
Recovery reconstructs allocation from `instances`, VM liveness, and
`resource_leases`.

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

## Core Types

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
    tier: &'a ResourceTier,
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

## Host Runtime Adapter

Mechanism is behind one interface:

```rust
trait HostRuntimeAdapter {
    fn host_kind(&self) -> HostKind;
    fn pressure_snapshot(&self) -> PressureSnapshot;
    fn apply_tier(&self, instance_id: &str, tier: &TierApplication) -> Result<(), RuntimeError>;
    fn resize_storage(&self, instance_id: &str, new_limit_gb: u32) -> Result<(), RuntimeError>;
    fn suspend(&self, instance_id: &str) -> Result<(), RuntimeError>;
    fn resume(&self, instance_id: &str) -> Result<(), RuntimeError>;
    fn snapshot(&self, instance_id: &str) -> Result<SnapshotRef, RuntimeError>;
    fn evict_warm_pool(&self, eviction: &WarmPoolEviction) -> Result<(), RuntimeError>;
    fn live_instances(&self) -> Result<Vec<LiveInstance>, RuntimeError>;
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
- `PressureSnapshot` is advisory and never authoritative.
- Admission and eviction policy are pure and unit-testable.
- Host adapters execute decisions and never choose policy.
- Warm pool cannot block explicit user deploy when an eviction can free enough
  capacity.
- Storage lease is written before storage growth starts.
- Runtime lease is written before VM start and released after VM stop.
- Mac custom `disk_gb` is not accepted while Mac disk is server-managed.
- UI profiles are product intent; backend tiers are scheduling policy.

## Trade-Offs

- CPU credits are excluded. Single-owner self-hosted scheduling needs weights,
  not billing fairness.
- RAM uses smooth degradation first. Hard caps exist only as safety nets.
- Mac hosts prioritize quality over density.
- Linux hosts use stronger resource controls because cgroup v2 gives reliable
  mechanisms.
- Snapshots are not the primary resize primitive because saved state
  compatibility depends on VM configuration.

