# Production pairing acceptance — work in progress

**Overall verdict: INCOMPLETE.** No TestFlight usage or broad-release acceptance
is claimed. The personal phone is excluded from the current experiment.

## Artifact work executed

`make qa-ios-export` was run on a real locally exported IPA from the corrected
pairing source. The IPA was not uploaded or installed by these checks.

| Observation | Result |
| --- | --- |
| IPA | `c6062a72af4eb0cacd3e2fa95cf7bdb541512cd34b410696b90d376bd360fe84` |
| App | `com.soyeht.app`, 1.1.19 (20), minimum iOS 16.2 |
| Main executable | `a8e8a47747eeb0e363807f82033a012532f13998de3f39269452091871fb559c` |
| Apple-anchored production-team signature | Accepted, including both extensions |
| Effective entitlements | `get-task-allow=false`, beta reporting active, push environment production |
| Profile | No provisioned-device list; no enterprise all-device provision |
| Real development-signed archive app | Valid signature; correctly refused as a distribution candidate |
| Damaged copy of main executable | Refused by codesign |
| Damaged copy of extension executable | Refused by codesign |
| Copy with missing profile | Refused by codesign |
| Missing, unexpected or duplicate extension | All refused by the inventory check; changed identity keeps the count, duplicate keeps the identity set |
| Missing required Make input | Stops with nonzero exit before inspection |

Eight artifact controls passed. The original IPA remained byte-identical. None
of these controls tested device behavior. The export's build number being 20
does not establish that this number is available for a new App Store upload.
In a disposable copy, disabling codesign verification made the calibration
fail on the damaged app executable. This mutation was exercised, not assumed.
Removing either the extension identity-set check or its count check in separate
disposable copies also made the calibration fail: signature rejection alone
cannot satisfy those policy controls.

## Physical evidence reviewed

The raw transcripts of the two previous Dev runs were reread independently:

| Transcript | SHA-256 |
| --- | --- |
| run2 | `608296bb5990e7579109ed6b9f7c2baefa6ad1d4120229236832f2b04ba3bfd2` |
| run3 | `19019792c1089c0cffffde8d2a26651a7caf438730c1be19250398e830a300f1` |

Each has one newly generated phone identity also present in the Mac's local
credential issuance, authenticated presence and pane-stream attach. The phone's
sent/accepted Mac identities agree. The captured engine household file hashes
are equal before/after and its captured lines contain no device-pair request.
Raw logs stay outside the public repository because they contain device/network
identifiers. The prior marker observations are not upgraded into the stronger
fresh-nonce protocol merely by rereading them.

These were real physical devices on the Dev profile, with both devices running
Tailscale. The terminal used a `.local` hostname. That does not establish a
deliberate Wi-Fi-only test or the resolved network route.

## Controlled comparison

The causal control added here is OLD versus NEW on the same dedicated phone and
Mac, with the same household/owner and observed initial state in each arm.
Builds are `3d8bc166` and `57b2f54b` (merged source tree `40293d33` has no content
diff from the latter). Reset is explicit and limited to the Dev phone fixture;
the Mac's household is not reset between arms. Driver success must include the
actual Connect tap, not merely receiving a claim.

The previously installed personal-phone source was `fdcb922b`, not `3d8bc166`.
`AwaitingMacView`, `HouseholdDevicePairingService` and `PairedMacsStore` are
byte-identical between those two revisions. Household/keychain error handling
changed elsewhere, so the OLD build is the immediate pre-fix control, not a
claim to reproduce the exact personal-phone binary.

The OLD run was subsequently observed and its transcript reread independently:
`5cdeefba55d62328d817d2d2a835baf741b5386bf01fa4ef6ce54da22f9c54fe`.
The driver recorded Connect pressed and the card still present. The newly minted
phone identity received a local secret but did not appear in the Mac's
authenticated-device set. The engine recorded a structured
`device_pairing.request.success`; only `owner_events/log.cbor` changed in the
household snapshot. This reproduces the dependency on owner approval in the
observed window.

There is a presence handshake at 16:20:06 in the OLD capture, **before** the
16:20:07 reset and 16:20:10 new device identity. It belongs to the previous pairing and
cannot count as an OLD success. The 170-second capture is shorter than the
300-second approval window: it does not prove an infinite spinner. The old
probe's LAN verdict used incorrect Tailscale metadata and is excluded from this
comparison. An inaccessible Add iPhone menu was explicitly reported by the
driver; the automatic Mac listener supplied the actual claim. Later retained
phone history records `pairing.failed stage=request cause=approvalExpired` at
16:25:30.263. This establishes expiration; that event does not identify an HTTP
status or distinguish a local approval deadline from an HTTP response.

## NEW arm: recovered from the actual interval

The first capture named NEW ended before its driver acted. NEW2 began after
that driver finished. Their summaries do not judge the NEW action. Instead,
the reviewer collected the dedicated test phone's retained log history and
queried the actual 16:28–16:31 interval, without installing, resetting or driving
either app. The local Mac log was queried for the same interval, restricted to
the Dev app process. Only retained events can be recovered this way.

| Observation | Result |
| --- | --- |
| Phone new device identity | Generated at 16:29:41.715 |
| Phone HMAC sent / accepted | 16:29:59.303 / 16:29:59.322, naming the expected Dev Mac |
| Mac presence authenticated | 16:29:59.333, naming exactly that new phone identity |
| Mac pane stream attached | 16:30:41.303, same phone identity and Mac app process |
| Driver | Connect pressed; card left; New session opened; command typed through the phone |
| Command output file | Present, zero bytes; filesystem birth/modify time 16:30:45.604 |
| Engine log, 16:28–16:31 | Ten lines, no device-pairing request or approval stage |
| Household | OLD-after equals NEW-before; subsequent NEW2 snapshot also unchanged |

The command was the existing driver's `touch`, not the proposed random-content
challenge with an observed absent-before condition. File creation time supports
creation during this action, but the stronger new protocol is still untested.
`mac_connection_confirmed` at INFO level was not retained in the later phone
history and is not claimed as recovered evidence. The driver and the matched
phone/Mac authentication and attach events are the observations used here.

### Actual running image, despite equal version strings

Both apps report 1.1.19 (20). The log's **sender image** supplies an independent
distinction for these Dev artifacts:

| Image | OLD | NEW |
| --- | --- | --- |
| `Soyeht.debug.dylib` UUID from the phone event | `7522B29F-8570-362E-98F6-57A26ACDC83A` | `D083A029-CE75-3C6B-9736-F1C092E600C2` |
| Local dylib SHA-256 | `e9e693cf99d98eaaf3a94f4b69e0f1b5a5b3172c5048984bae6b0de25eb3c24a` | `a06cc0dd92c24c5b3925d17a9dadb6ede918eab9afbdf874fac9f697f2ebb5f3` |

Each UUID matches its local built artifact; both local app bundles passed deep,
strict signature verification. The main executable's UUID is **identical** in
these two Dev builds: comparing only that launcher would miss the changed code
in the debug dylib. UUID comparison establishes link-image identity, not a
cryptographic attestation of runtime memory. The local bundle signature is a
separate observation.

Raw observation digests (files retained locally, not published):

| Observation | SHA-256 |
| --- | --- |
| OLD phone JSON interval | `84d2151b5c5fa100a9974ccbc984a0ea7f8006a8be80b91f35120657f8a414cd` |
| NEW phone JSON interval | `224bc0b213f4e19beb852e496e2b57942ba9573d15ddd57308025bceb7b549a6` |
| NEW Mac JSON interval | `bf9307bf46c1b9c6a8cc801a999e078c6d53c842cf754b72e7a25a4b08fe82dc` |

This supports the regression comparison in this owned-home fixture: the old
path requested owner approval and timed out; the corrected image authenticated
the fresh phone and reached a terminal. The test phone was not inherently an
always-successful environment. This result does not qualify all users, networks
or distribution channels.

### A later NEW attempt

The separate 16:37 attempt was also read from the retained phone and Mac logs.
It used the same NEW sender image UUID. A new phone identity was generated at
16:37:14.427; the phone sent HMAC and received its acknowledgment at 16:37:29.966
and 16:37:29.990. The Mac authenticated that exact fresh identity at 16:37:30.004
and attached its pane stream at 16:38:12.141. The driver's new `touch` marker has
filesystem birth/modify time 16:38:16.754. The 16:37:10 handshake belongs to the
previous identity, before the reset, and is excluded.

The recovered phone interval has SHA-256
`36d1b24cf6ef1b25bae42d38b8ba3cefea7cad8ae5126f65b56cd0a204663243`;
the Mac interval has SHA-256
`8004d75fcd546b22580fadcd119b5b3295d8c987e04245e8d566d8182a78a242`.
This is another observed success under the same fixture, not another network,
installation history or distribution channel.

### Capture covering the complete driver

The orchestrated 17:12:50–17:14:01 run contains the whole driver, with exit 0 and
its terminal readback completed. The transcript digest is
`2a79b9650abfc8947a96a0c16a167e74f34faed2cdc944eeaac8b37404358b51`.
Its fresh phone identity was generated at 17:12:57; the phone and Mac
authenticated it at 17:13:14, and the Mac attached its pane at 17:13:56. The
driver's marker was created at 17:14:00.856. Household snapshots match, with no
device-pairing request or approval events in the captured engine log.

This capture records `endpoint.persisted class=tailnet` at 17:13:13.996. The
Mac-local path does persist an endpoint. The old `TAILNET-KEPT` finding instead
reads `pair.endpoint`, an HTTP ceremony this path does not execute; its initial
failure does not judge the terminal's network route. Disabling an irrelevant
ceremony check does not establish Wi-Fi-only or remote connectivity.

The separate reattach attempt stopped during automation of the initial command,
before the interruption/reconnect. One attach is observable in its Mac log; a
completed reattach test is not. A stale saved WDA session was observed later,
but the historical timeout's cause was not established from that observation.

VPN navigation on the dedicated test phone reached the selected Tailscale
configuration, showing both VPN Connected and Connect On Demand enabled. No
preference was changed during this navigation. The controls are reachable;
absence from the first Settings viewport was not a demonstrated restriction.
### VPN-off discovery exposed another product refusal

The later 17:56:22–17:57:45 run began with VPN **Not Connected** and Connect On
Demand disabled, read from the two separate Settings pages. Both were still off
after the run. The exact selected profile was retained. Restoring the settings
required navigating again from the Settings root; the initial automated restore
refused the unexpected page. The final readback confirmed Connect On Demand=1
and VPN Connected=1. Raw screenshots and timestamped state observations remain
local. An earlier attempt without these observations does not establish VPN
state, and its address advertisements cannot substitute for that measurement.

The corrected owner-approval build (`57b2f54b`) generated a fresh phone identity
at 17:56:28.413. The Mac issued its local credential to that identity nine times;
the phone received nine existing-house claims containing that credential. Each
was refused with `pairing.failed stage=discovery` and
`PairingAddressError.noReachableAddress`. The card never appeared, no fresh
presence handshake occurred, and the driver did not complete. The 17:56:24
handshake predates the reset and belongs to the previous identity.

This is an observed **product refusal before Connect**, despite the driver's
incomplete result. It is not a failed attempt to press a visible Connect button.
Household snapshots are unchanged. It does not establish successful Wi-Fi-only
pairing or terminal use.

Code review traced the refusal to the discovery callback selecting an HTTP
`addDevice` route before distinguishing Mac-local confirmation. The latter uses
the separately supplied presence/attach credential and does not enroll the
phone in the household. A missing eligible engine route therefore blocks a
different operation. The correction is being developed separately; a proposed
change or a unit test will not change this physical result into a pass.

| Local evidence | SHA-256 |
| --- | --- |
| VPN-off transcript | `aebc720c89516d4d70294f3e107f25d9e2356e20d76eebe331de5218cd5006a1` |
| Orchestrator run record | `dde1550145cb33671ef0bb63f1dd91c52d4117c33345e2660b9e02fd993e41e0` |
| VPN state before driver | `241ca6913ce1318ba50370dfc22ac6bf769361cd5f1573622bb320fa17f994c0` |
| VPN state after driver | `61f0491b1a6746c9b2be50eca24b50411cc38152936425d9033bc8058d07c620` |
| Baseline restored | `5e10e7cad5e748c5576020b6b73a5b94f3eafda9e57d62a388b4fd9a9fdc78c1` |

Deliberate Wi-Fi-only pairing is now **FAILED in the observed discovery path**.
Fresh-command reconnect, retained-keychain upgrade and TestFlight installation
remain **NOT RUN or awaiting evidence**. Do not infer their results from this
comparison.

See [the acceptance procedure](../../domains/production-pairing-acceptance.md)
for evidence requirements and the laboratory/distribution limitations. No
complete automatic iOS promotion gate exists in this change.
