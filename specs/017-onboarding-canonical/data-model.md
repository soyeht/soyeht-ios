# Phase 1 Data Model — Onboarding Canônico Soyeht

**Feature**: 017-onboarding-canonical
**Date**: 2026-05-09

## Entities

### Casa (Household)

A unidade central de identidade. Soberana, local-first, sem servidor central.

| Field | Type | Constraints | Notes |
|---|---|---|---|
| `hh_id` | string (UUID v4 stringificado) | unique, immutable | Identificador interno; não exposto na UI exceto debug |
| `hh_pub` | bytes (33 bytes SEC1 compressed P-256 EC) | unique, immutable | Identidade criptográfica pública |
| `hh_priv_ref` | SecKey ref (Secure Enclave) | exists, never extractable | Constitution v2.0.0: `kSecAttrTokenIDSecureEnclave` + `.biometryCurrentSet` |
| `name` | string | 1–32 chars UTF-8, no `/`, `:`, `\\`, `\0` | Editável pelo operador (ex: "Sample Home") |
| `avatar` | Avatar (computed) | derivado de `hh_pub` (FR-046) | Determinístico, persistido pra evitar recalc em cada render |
| `created_at` | timestamp (UInt64 unix seconds) | immutable | Pra "última atividade" UX |
| `bootstrap_state` | BootstrapState | see state machine below | Lifecycle current state |

**Validation**:
- `name` length validated antes do `POST /bootstrap/initialize` (cliente + servidor)
- `hh_pub` MUST corresponder ao `hh_priv_ref` mantido em SE (verificável via test signature)

**Relationships**:
- 1 Casa has 1..N Moradores
- 1 Casa has 1..N Computadores da casa (this delivery: 1)
- 1 Casa has 1 Avatar (computed)

---

### Avatar da casa

Visual identity. Computed once at house creation, persisted.

| Field | Type | Constraints |
|---|---|---|
| `emoji` | string (single Unicode scalar from curated list) | from 512-emoji catalog |
| `color_h` | UInt16 | 0..359 (hue degrees) |
| `color_s` | UInt8 | 60..85 (saturation %) |
| `color_l` | UInt8 | 50..70 (lightness %) |

**Derivation** (see research.md R4):

```
hash = SHA-256(hh_pub)
emoji_idx = u32_be(hash[0..4]) mod 512
color_h = u16_be(hash[4..6]) mod 360
color_s = 60 + (hash[6] mod 26)
color_l = 50 + (hash[7] mod 21)
```

**Invariant**: same `hh_pub` ALWAYS produces same `(emoji, color_h, color_s, color_l)`.

---

### Morador (Member device)

A device pessoal autorizado: iPhone, iPad, Mac.

| Field | Type | Constraints |
|---|---|---|
| `device_id` | string (UUID v4) | unique within Casa |
| `device_pub` | bytes (33 bytes SEC1 compressed P-256 EC) | unique within Casa |
| `device_priv_ref` | SecKey ref (Secure Enclave) | local-only, never replicated |
| `display_name` | string | 1–48 chars UTF-8 (e.g., "iPhone Owner") |
| `device_type` | enum {`iphone`, `ipad`, `mac`} | |
| `joined_at` | timestamp (UInt64 unix seconds) | |
| `last_seen_at` | timestamp (UInt64 unix seconds) | updated by gossip |

**This delivery**: only `iphone` types are added as moradores (Mac is host machine, not a morador). Future spec covers operator-Mac as morador.

**Relationships**:
- N Moradores belong to 1 Casa

---

### Computador da casa (Host machine)

Mac onde Soyeht engine vive. This delivery: ≤1.

| Field | Type | Constraints |
|---|---|---|
| `machine_id` | string (UUID) | unique |
| `machine_pub` | bytes (33 bytes SEC1 compressed P-256 EC) | unique |
| `machine_priv_ref` | SecKey ref (Secure Enclave) | local |
| `display_name` | string | derivado de `Host.localizedName` (e.g., "Developer Mac") |
| `platform` | enum {`mac`, `linux`} | this delivery: only `mac` |
| `joined_at` | timestamp | |
| `engine_version` | semver string | reportado via `/health` |

---

### BootstrapState (state machine)

Estado interno do engine no ciclo de bootstrap.

```
                  ┌──────────────────────────────────┐
                  │                                  │
   uninitialized ──[POST /initialize OK]──> ready_for_naming  ─[name rcvd]─>  named_awaiting_pair
        ▲                                                                              │
        │                                                                              │
        └──[POST /teardown]────────────────────[1st morador paired]──> ready
                                                                       │
                                                                       │
                                       (out-of-scope future: ──[restore initiated]──> recovering)
```

**Transitions**:

| From | Event | To | Guard / Side-effect |
|---|---|---|---|
| `uninitialized` | `POST /bootstrap/initialize {name}` | `ready_for_naming` | name validated; state row created (no key yet) |
| `ready_for_naming` | name confirmed (atomic write w/ key gen) | `named_awaiting_pair` | P-256 keypair generated in SE; persisted; pair_qr_uri returned |
| `named_awaiting_pair` | first morador pareado bem-sucedido | `ready` | Bonjour TXT updated `bootstrap_state=ready, device_count=1`; APNs push fired (Caso A) |
| any | `POST /bootstrap/teardown` | `uninitialized` | confirm strong; wipe state row, unregister LaunchAgent if requested |

**This delivery**: `recovering` state stub-only (engine accepts the enum but doesn't transition into it). Future spec.

---

### SetupInvitation

Ephemeral capability for Caso B handshake.

| Field | Type | Constraints |
|---|---|---|
| `token` | bytes (32 random bytes) | crypto-random; single-use |
| `owner_display_name` | string | optional; pre-fill suggestion for "Casa <name>" |
| `expires_at` | timestamp (UInt64 unix seconds) | now + 3600 max |
| `iphone_device_id` | UUID | local-only; correlates iPhone session |
| `iphone_apns_token` | bytes (≤32) | pra Mac fazer push após install |

**Lifecycle**:
- Created on iPhone when user confirms "Sim, estou no Mac" (cena PB2)
- Published via `_soyeht-setup._tcp.` Bonjour TXT
- Claimed by Mac via `POST /bootstrap/claim-setup-invitation {token}` after engine install
- Expired/cancelled if not claimed within `expires_at` or user backs out

**Single-use**: claim atomic; second claim with same token returns `409 token_already_claimed`.

---

### TelemetryPreference

Opt-in flag persistido localmente.

| Field | Type | Default | Mutable |
|---|---|---|---|
| `opt_in` | Bool | **false** (FR-073) | yes (Settings) |
| `decided_at` | timestamp? | nil at first launch | set on first decision |
| `last_event_sent_at` | timestamp? | nil | for rate-limit window |

Persistido via `@AppStorage("telemetry_opt_in")` (iOS) e `UserDefaults` (Mac).

---

### CarouselSeen

Flag pra carrossel já apresentado (FR-021).

| Field | Type | Default |
|---|---|---|
| `seen_at` | timestamp? | nil |

Persistido via `@AppStorage("carousel_seen_at")`. `nil` = never seen → mostrar; non-nil = já viu → suprimir auto-show. Settings > Reapresentar tour limpa.

---

### TelemetryEvent (enum, FR-071)

Eventos enumerados, anônimos, sem PII.

```swift
enum TelemetryEvent: String, Codable {
    case installStarted        // Soyeht.app primeira abertura
    case installCompleted      // Engine rodando + /health 200
    case installFailed         // Com error_class enum, sem mensagem livre
    case firstPairCompleted    // 1º morador paireado
    case firstPairFailed       // Com error_class enum
    case casaCreated           // POST /initialize 200
    case deviceAdded           // Morador added (futuro: device count > 1)
}

enum InstallErrorClass: String, Codable {
    case noInternet
    case airdropFailed
    case appleIdMismatch        // log only when telemetry-relevant; nunca expor pro user
    case daemonBindFailed
    case keychainAclDenied
    case bonjourPublishTimeout
    case smappserviceFailed
    case diskFull
    case gatekeeperBlocked
    case userCancelled
}
```

**Payload max**: ~120 bytes CBOR-encoded. Send batched ≤1/min, max 50/day.

---

## Cross-Repo Schema Alignment

Schemas frozen em `theyos/specs/004-onboarding/contracts/*.md`. iSoyehtTerm SoyehtCore types MUST mirror exact field names + types.

Validation gate: `swift build -Xswiftc -strict-concurrency=complete` + `cargo test` ambos green em CI antes de PR pareados merge.

---

## Validation Rules Summary

| Rule | Enforcement Layer |
|---|---|
| `name` 1–32 UTF-8 chars, no filesystem-bad chars | iOS UI (TextField validation) + Swift client + Rust handler |
| `hh_pub` is valid SEC1 compressed P-256 (33 bytes, lead byte 0x02 or 0x03) | SoyehtCore `HouseholdPubKey` type + Rust `p256` crate parse |
| `token` is exactly 32 bytes | Both sides |
| `expires_at` is in future at claim time, ≤3600s ahead at issue time | Both sides |
| `device_count` ≥ 1 in `bootstrap_state=ready` | Engine post-pair commit |
| TelemetryEvent is in enum (not string) | Codable rejects unknown |
