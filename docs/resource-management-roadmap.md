# Resource Management Roadmap

Soyeht is self-hosted: one human owns the host and the Claws competing for
resources. The product model is not multi-tenant cloud fairness. The goal is an
Apple-grade local scheduler: the user expresses intent, and Soyeht manages the
machine without making it feel broken.

## Product Contract

- The main UI exposes `Efficient`, `Standard`, and `High`.
- CPU, memory, and storage stay behind `Advanced`.
- Default installs use `Standard`.
- Warm pool capacity is cache only; explicit user deploys always win.
- Mac hosts prefer fewer, better-served Claws.
- Linux hosts can be more elastic.
- Technical errors such as `insufficient CPU` are translated into actionable
  states: choose another server, use Standard, or stop another app.

## Internal Model

Each Claw profile should map to:

- `boot_floor`: minimum technical resources needed to be useful.
- `target`: the selected profile's normal allocation.
- `burst_ceiling`: the maximum allowed when the host is idle.

These are not tenant guarantees. They are scheduling hints for a cooperative
single-owner system.

## Linux Direction

- Add a ResourceManager as the single admission and pressure policy layer.
- Move Firecracker processes into cgroup v2 groups via runner wrapper first;
  consider Firecracker jailer later for stronger isolation.
- Use `cpu.weight` by profile tier; avoid CPU credits.
- Use `memory.high` for smooth degradation and `memory.max` only as a safety
  net for runaway workloads.
- Use `io.weight` and, for background/warm-pool work, `io.max`.
- Monitor CPU, memory, and IO pressure before admitting new work.
- Add Firecracker balloon support after pressure metrics exist.

## Mac Direction

- Keep Mac scheduling conservative.
- Use Virtualization.framework `cpuCount` and `memorySize` as fixed VM
  configuration at launch time.
- Do not aggressively oversubscribe macOS guests.
- Limit concurrent disk-heavy operations.
- Disable or strictly bound warm pool behavior on Mac.
- Use macOS memory pressure and thermal state as admission signals.

## Storage Direction

- Start each Claw with a safe default storage size.
- Add automatic storage growth later, always with a configured ceiling.
- Keep host free-space reserve mandatory.
- Grow Linux storage first; macOS storage resize requires separate validation.
- Never shrink user storage automatically.

## Resize Direction

- First version applies CPU and memory changes through a graceful restart.
- Do not promise instant upgrades.
- Snapshots are useful for fast resume, but they are not the first resize
  primitive because VM saved state compatibility depends on configuration.

