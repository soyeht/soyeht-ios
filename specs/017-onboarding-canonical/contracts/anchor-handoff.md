# Contract — `GET /pair-machine/anchor-handoff`
<!-- mirror of theyos:005/contracts/anchor-handoff.md as of 6c78fe7 -->

**Feature**: 017-onboarding-canonical
**Cross-repo source of truth**: `theyos/specs/005-soyeht-onboarding/contracts/anchor-handoff.md`
**This file**: mirror referenced in iSoyehtTerm. Sync verified via cross-repo CI workflow.

## Status: MVP (promovido de deferred 2026-05-09)

Promovido após alinhamento entre agente-front e agente-backend. anchor-handoff elimina QR scan no caminho comum (95% dos pareamentos sem QR per SC-007), sendo Apple-grade puro vs deferral.

Threat model em [theyos/docs/household-protocol.md § Threat Model: anchor-handoff Tailnet trust boundary] (referenciado, não duplicado).

## Purpose

Permitir que iPhone (ou outro device pessoal autorizado pela casa) pegue `anchor_secret` direto da máquina candidate via Tailnet, eliminando QR scan visível ao usuário no caminho happy. QR scan permanece como fallback explícito quando sinais de confiança Tailnet falham.

## Endpoint

`GET /pair-machine/anchor-handoff`

**Authentication**:
- Tailscale ACL filter: endpoint só responde a peers detectáveis no mesmo tailnet (ACL imposed by engine via interface check).
- Adicional: biometric proof recente (Face ID em últimos 30s no iPhone) — request inclui `X-Biometric-Timestamp` + signed assertion via `D_priv`.

**Idempotent**: yes; cada call retorna o mesmo `anchor_secret` enquanto candidate está em estado `named_awaiting_pair`. Após primeiro morador paireado, retorna 410 Gone.

## Request

No body. Query params:
- `requestor_device_id`: UUID do device requesting (iPhone)
- `nonce`: 32-byte hex (replay prevention)

Headers:
- `X-Biometric-Timestamp`: unix seconds when biometric was satisfied
- `Authorization`: PoP-signed by `D_priv` (existing pattern from PR #75)

## Response (200 OK)

Content-Type: `application/cbor`

```
{
  "v": 1,
  "anchor_secret": <32-byte bytes>,
  "expires_at": <unix seconds>          // typically now+300 (5min window for client to use)
}
```

## Error envelope (4xx, 5xx)

```
{ "v": 1, "error": <text code>, "message": <text> | null }
```

### Error codes

- `"tailnet_required"` (403) — request came from non-Tailnet interface (LAN bruta, public Wi-Fi, etc.)
- `"biometric_too_old"` (401) — `X-Biometric-Timestamp` > 30s ago
- `"signature_invalid"` (401) — PoP signature doesn't verify
- `"replay_detected"` (401) — nonce already used
- `"not_in_pairing_state"` (409) — candidate state ≠ `named_awaiting_pair`
- `"already_paired"` (410) — first morador already paired; anchor exhausted

## Security notes

- `tailnet_required` enforced server-side via interface name detection (cannot be bypassed by spoofing headers).
- 30-second biometric freshness prevents stale auth from compromised but unattended iPhone.
- Replay nonce stored in memory with TTL 5min; sufficient for single-pairing flow.
- See threat model in `theyos/docs/household-protocol.md` for full attacker analysis.

## Test fixtures

`Packages/SoyehtCore/Tests/SoyehtCoreTests/AnchorHandoffClientTests.swift`:
- Happy path: signed request → 200 with anchor_secret bytes
- Each error code path
- Tailnet-required enforcement (mock LAN-bruta interface)
- Biometric staleness rejection
- Replay nonce duplicate rejection
- 30s freshness window edge cases (29s OK, 31s rejected)
