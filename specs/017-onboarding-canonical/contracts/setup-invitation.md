# Contract — Bonjour service `_soyeht-setup._tcp.`
<!-- mirror of theyos:005/contracts/setup-invitation.md as of 6c78fe7 -->

**Feature**: 017-onboarding-canonical
**Cross-repo mirror**: `theyos/specs/004-onboarding/contracts/setup-invitation.md`

## Purpose

iPhone (Caso B) publishes this service after AirDropping the installer to the Mac. Mac (post-install) browses for it and claims via `POST /bootstrap/claim-setup-invitation`. Result: Mac's first launch skips house-naming (UX cena MA — instead, name is collected on iPhone).

## Service metadata

- **Type**: `_soyeht-setup._tcp.`
- **Port**: dynamic (`NWListener` allocates)
- **Network constraint**: ONLY published over Tailscale interface (per FR-040 + R2). Plain LAN publication only when user has opt-in flag set per-network (FR-041).

## TXT record

CBOR map encoded as base64url, stored as TXT key `m`:

```
{
  "v": 1,
  "token": <32-byte bytes>,                   // crypto-random; single-use
  "owner_display_name": <text> | null,        // ≤32 UTF-8 chars; pre-suggestion for "Casa <name>"
  "expires_at": <uint>,                       // unix seconds; MAX now+3600
  "iphone_apns_token": <≤32-byte bytes> | null  // for Mac post-install push notification
}
```

CBOR is deterministic (RFC 8949 §4.2.1). base64url ensures DNS-safe TXT encoding.

**TXT length budget**: total ≤1300 bytes (DNS-SD spec). With 32+32+96+8+32 = ~200 bytes raw + CBOR overhead + base64url 4/3 expansion ≈ 280 bytes. Cabe folgado.

## Lifecycle

```
[user confirms "Sim, estou no Mac"]
        │
        ▼
[iPhone generates token + publishes service]
        │
        ▼
[Mac AirDrop-receives Soyeht.dmg, user installs]
        │
        ▼
[Mac engine boot → discovery: NWBrowser para _soyeht-setup._tcp. on Tailnet]
        │
        ▼
[Mac sees TXT, extracts token]
        │
        ▼
[Mac calls POST /bootstrap/claim-setup-invitation {token} on its own engine]
        │
        ▼
[Engine validates → transitions state, accepts owner_display_name as initialize hint]
        │
        ▼
[iPhone receives APNS push when Mac calls /bootstrap/initialize → app foreground → next UX scene]
        │
        ▼
[iPhone un-publishes service (claimed)]
```

**TTL**: 3600s. If not claimed within window, iPhone un-publishes and shows "Tempo esgotado. Tentar de novo?" + retry button.

**Single-use**: claim removes the service from iPhone; second claim attempt with same token is impossible (service gone).

## Security

- Token is the only authenticator. Knowing the token = capability to influence Mac's first `bootstrap/initialize` call.
- Token entropy: 32 bytes random (256 bits). Brute-force in TTL window is infeasible.
- iPhone publishes ONLY on Tailscale interface — only Tailnet members can browse the service.
- Tailnet ACL is the user's responsibility (Tailscale UI). Constitution III scope.

## Failure modes

- iPhone goes offline mid-window: service publication interrupted. Mac NWBrowser retries on backoff. If iPhone returns within TTL, claim succeeds. If not, expires.
- Mac in different Tailnet from iPhone: discovery fails. UI surfaces "Não encontrei seu Mac na sua rede privada. Configure Tailscale em ambos." (FR-060).
- TXT corrupted (publisher bug): NWBrowser yields empty/invalid TXT; Mac retries after backoff. After 3 fails, surface error.

## Testing

Mock `NWListener`/`NWBrowser` pair em `SetupInvitationPublisherTests.swift` + `SetupInvitationBrowserTests.swift`:
- Publish → discover → TXT decode round-trip
- Token expiry behavior
- Single-use enforcement (republish after claim is rejected)
- Tailnet-only filter (mock interface name)
