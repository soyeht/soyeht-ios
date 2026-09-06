# Executable pairing contract

Run from the Swift checkout, with the engine checkout supplied explicitly:

```sh
python3 scripts/pairing-contract-gate.py --theyos-root /path/to/theyos
```

The gate builds the current source in both checkouts. It runs a Rust test host
with temporary software identities and ephemeral loopback listeners, then uses
Swift request producers, clients, certificate validation and session storage.
It never installs an app, launches an engine binary, reads installed household
state, advertises Bonjour, or operates a device.

`route-catalog.json` describes every required route and its execution boundary.
Engine routes use production routers, including the first-owner and delegated
pairing routers shared with production. Phone routes execute the publisher's
shared dispatch and codecs; the actual Swift verification response is consumed
by the Rust callback decoder. Legacy by-code and reissue routes use their real
handlers and Swift link decoders without inventing a product caller.

The live scenarios cover fresh initialization, first-owner pairing, delegated
pairing with tailnet present/absent/unknown, owner request review and approval,
and another Mac joining the household. The persisted endpoint is loaded back
through `HouseholdSessionStore`. Logical fixture addresses are routed to the
isolated HTTP host; this substitutes transport destinations, not wire codecs.
Listener facts are controlled fixtures. Actual network reachability, interface
policy, Keychain prompts and GUI approval remain separate device E2E evidence.

Every run must also activate and reject these regressions:

| Control | Mutation | Required evidence |
| --- | --- | --- |
| `renamed-route` | Send the visibility request to a renamed path | Actual HTTP 404, then client rejection |
| `renamed-expiry` | Rename `expires_at_unix` in an actual successful response | HTTP 200 before mutation, then decoder rejection |
| `persisted-lan` | Replace tailnet with LAN at the storage boundary | Pairing completes; loaded session differs from the selected endpoint |

Fault injection exists only in the conditional test target. Production has no
fault switch. The publisher dispatch never starts a network listener in this
suite. To exercise the analogous storage regression on a Dev build, inject a
`HouseholdSecureStoring` decorator at the pairing service's `sessionStore`;
mutate only the active-session endpoint after a successful response. Compare
that run with the normal dependency and discard the injected build afterwards.

Missing checkouts, missing sources, planned routes, uncovered routes, skipped
contract execution, failed builds and unactivated controls all fail the gate.
There is no option to accept an old build. A receipt records source hashes and
both local commit IDs; source drift during verification fails the run. Evidence
lives in the temporary directory printed by the command. The gate does not
publish its temporary certificates, logs or receipt.

Release remains coordinated across Mac, engine and iOS. An older iOS payload
without an installation profile cannot authorize an automatic claim. Complete
the device E2E matrix before updating or releasing versions.
