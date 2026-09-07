# Production pairing acceptance — work in progress

**Overall verdict: INCOMPLETE.** No TestFlight usage or broad-release acceptance
is claimed. The personal phone is excluded from the current experiment.

## Artifact work executed

`make qa-ios-export` was run on a real locally exported IPA from the owner-approval
correction (`57b2f54b`). This export does not contain the later LAN correction
`ba31526e`. The IPA was not uploaded or installed by these checks.

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
different operation. The correction was developed separately in `ba31526e`. The failing run remains
a failure; its subsequent physical comparison is recorded below.

| Local evidence | SHA-256 |
| --- | --- |
| VPN-off transcript | `aebc720c89516d4d70294f3e107f25d9e2356e20d76eebe331de5218cd5006a1` |
| Orchestrator run record | `dde1550145cb33671ef0bb63f1dd91c52d4117c33345e2660b9e02fd993e41e0` |
| VPN state before driver | `241ca6913ce1318ba50370dfc22ac6bf769361cd5f1573622bb320fa17f994c0` |
| VPN state after driver | `61f0491b1a6746c9b2be50eca24b50411cc38152936425d9033bc8058d07c620` |
| Baseline restored | `5e10e7cad5e748c5576020b6b73a5b94f3eafda9e57d62a388b4fd9a9fdc78c1` |

### LAN correction: same discovery input, then a physical VPN-off run

`ba31526e47f323e28a12ddc510518819e068561a` changes the actual claim consumer and
its tests. A claim can offer Mac-local confirmation without an eligible engine
HTTP route only when its event is `existingHouseOffered`, it carries the local
credential, and its pairing URL parses as `HouseholdDevicePairingLink`. The
invitation token and installation profile are checked before this branch.
The event alone does not distinguish first-owner setup: a first-owner
`PairDeviceQR` in the same event still follows strict HTTP route selection.
The credential remains deferred until Connect, and authenticated presence is
required before leaving the card. No household enrollment is started.

The behavioral test invokes `handleDirectClaim` with an input whose HTTP
`chooseAddress` explicitly throws `noReachableAddress`. Before the fix, the
actual card/Connect assertions failed. After the fix, 12 consumer tests and 43
existing presentation guards passed (55 total, no failures). Negative cases
include token/profile/port/event mismatches, first-owner input without an engine
route, and a late local credential arriving at the existing confirmation card.

The physical candidate is development-signed `com.soyeht.app.dev` 1.1.19 (21),
built from that clean revision and read back as build 21 from the test phone's
installed-app inventory. Its actual phone events name `Soyeht.debug.dylib` UUID
`3B8155A8-1C58-3336-A6A0-1B08A49FDE44`, matching the signed local artifact
(SHA-256 `638d03687198eb375b25518e91d1e12de65605a67b58c6cfb24e80d1c5c0d7a8`).
The Mac Dev app remained the existing `57b2f54b` build; no Mac/engine replacement
was needed for this correction.

In the observed 18:19:53–18:21:04 driver window, the fresh phone identity was
created at 18:19:59.578. The new Mac-local card branch ran at 18:20:13.477.
The phone sent HMAC and received acknowledgment at 18:20:16.461/.479;
`mac_connection_confirmed household_enrolled=false` followed. The Mac
credential/authentication/attach records name that same fresh phone. Its pane
stream attached at 18:21:00.181, and the driver completed its terminal action.
Household hashes for all ten observed files match before/after; the captured
engine log has no device-pairing request or approval.

A separate terminal challenge was then typed through the still-open phone app
at 18:21:21–18:21:27. The fresh output path was observed absent before input;
the Mac file's bytes were compared to the newly generated nonce and matched
exactly. This action is **outside** the original collector's driver window:
its own gesture script and timestamped `challenge.json` retain the observation.
The file was independently reread and still matched. This is stronger than the
earlier `touch` marker, and is not retroactively attributed to the old captures.

VPN Not Connected=0 was read from Settings before the driver and after the
extra command. Connect On Demand was also observed off. The phone's presence
used the local hostname and the Mac observed a LAN link-local peer. The engine
endpoint persisted in the phone is still a tailnet address; initial successful
presence cannot by itself establish how reopening uses that stored endpoint.
Finally, Connect On Demand=1 and VPN Connected=1 were read back. Independent
review confirmed the fresh subjects, exact nonce file, VPN observations,
unchanged household and absence of enrollment.

| Local evidence | SHA-256 |
| --- | --- |
| Fixed VPN-off transcript | `d9811486722f0468ba28d2b547507585a7218f02f10bb1d71bac0ca79fc81e39` |
| Phone event JSON, including sender image | `d6ff303722932eb4fbe3af9c3a6840c61dbc102e6322f46d78316eb62190b121` |
| Exact-content command observation | `5b0025b1a490696c9e1e504705008aba7d0a4bcdbfba1eedf4d9496d214eb229` |
| VPN before driver | `9e16c46e7e9d12dd31bc2b33085c983ce780e3151fea12e98c61b97831b24a69` |
| VPN after command | `91ae3661202673ebd46618755a2be9bd81540f6f4a01f6c3a93f3d833798db2e` |
| Restored baseline | `c1d10911eeaa9076563bed6d184ea58effc2e0f48b3b3858e4e818f13ac46aa9` |

This is a physical **pass for initial Mac-local pairing and terminal use with
the phone VPN disabled**, following a physical product failure before the fix
on the same dedicated pair. It does not establish an installation through the
store, another phone/network, a retained-keychain upgrade, remote access, or all
supported first-owner scenarios. The phone-app relaunch observation follows below; network-loss recovery is a
separate case and is not inferred from relaunch.

### Reopening the same pane with VPN still off

A separate run reused the newly paired phone and the same terminal pane, with
no reset or enrollment. VPN Not Connected=0 was observed at 18:32:21, before
opening the app. The first new command wrote a fresh nonce and its shell PID to
previously absent paths. The nonce was compared byte-for-byte on the Mac, and
`ps` independently read that PID, parent, start time and TTY.

The operator then terminated **only the observed Dev phone app PID** using
`devicectl` SIGTERM, reopened the app through WDA and selected the exact same
pane row. This is a process relaunch test, not a claim to have performed a
manual app-switcher gesture. The phone PID changed. Both app processes emitted
events from the build-21 code image identified above. Presence chose the local
hostname before and after relaunch; the second HMAC/ack occurred at
18:32:43.851/.871. Mac logs show fresh attach grants and stream attachment for
the target pane at 18:32:30.118 and 18:32:50.557.

The reopened terminal accepted a second fresh-nonce command. Both output files
were reread with exact contents, and the shell's kernel identity remained the
same. Read-only engine inventories agree on the target's `session_instance_id`,
PID and supervisor backend; both reported PIDs equal the command's shell PID.
The supervisor PID and boot ID also remained unchanged. No engine or supervisor
restart was performed. Other listed panes were not driven.

VPN Not Connected=0 was still observed at 18:33:39 and Connect On Demand=0 at
18:33:41, after both commands. They were restored to 1, with VPN Connected=1 at
18:33:48. The owned Mac log capture was terminated in `finally`. Phone history
was collected afterward using the observed 18:31:30–18:33:02 action interval;
both authentication sequences and the loaded code identity are present.

| Relaunch evidence | SHA-256 |
| --- | --- |
| Run result | `ef9dba365de6b2af7e6bd02b2dcc619056cc25a539d78f69623eb3af06e9e691` |
| First exact-content command | `16581247140e6f6b47b3882751c850b08fbf9906b96645489f7a070b2332e7ab` |
| Second exact-content command | `b6c844f31b3240fd8311856edfd1a6deb69d83a46b6ebded6d97999829b3ceec` |
| Phone event JSON | `f46f8d38c3e767230ebb5a55839abe7a847dacfacfbb4d052f2e10ec629d3011` |
| Mac capture | `0ff87feb1948840817909a4c51cea21793ece10afd0bbb63378f75478418eb8d` |
| VPN off before | `05b1b909a9ea9c458f9f034d8d685ab64289174dcb5c76d921003b05b433f61d` |
| VPN off after | `c9ecef9e42d85e393935e8ab21a709cfcb5237f3448d5e81e3a14194b26a2d9e` |
| VPN restored | `22d9b9f3b290fcf3c98fce34e16f89067b8dce94b8458de7c9cb4b3ee2f84218` |

This closes **app relaunch and same-session terminal reuse with the phone VPN
disabled in this fixture**, including the case where a tailnet engine address
remains persisted. It does not cover losing/restoring Wi-Fi, moving outside the
LAN, rebooting the phone, or upgrading to a store-distributed app. Those remain
separate, unmeasured cases.

## Coverage remaining

The two observed product regressions now have before/after evidence on the
physical Dev pair: owner-approval dependency and the unnecessary engine-route
requirement. VPN-off initial terminal use and VPN-off app relaunch are measured.
Broad-distribution acceptance remains **INCOMPLETE**: there is no TestFlight
installation of this LAN fix, no retained-keychain upgrade of the distributed
iOS app, and no physical matrix across supported OS/device/locale combinations,
first-owner setup, or a genuinely remote network in this work. The local IPA
inspection near the top of this report belongs to the earlier owner-approval
fix, not the build-21 LAN candidate. No customer device or production service was
modified during these additional LAN runs.

See [the acceptance procedure](../../domains/production-pairing-acceptance.md)
for evidence requirements and the laboratory/distribution limitations. No
complete automatic iOS promotion gate exists in this change.
