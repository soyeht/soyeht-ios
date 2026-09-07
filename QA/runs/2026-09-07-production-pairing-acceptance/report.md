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
| Missing required Make input | Stops with nonzero exit before inspection |

Five artifact controls passed. The original IPA remained byte-identical. None
of these controls tested device behavior. The export's build number being 20
does not establish that this number is available for a new App Store upload.

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

## Next controlled comparison

The missing causal control is OLD versus NEW on the same dedicated phone and
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

At this report revision, the OLD/NEW comparison, deliberate LAN-only run,
fresh-command reconnect, retained-keychain upgrade and TestFlight installation
remain **NOT RUN or awaiting evidence**. Do not infer their result from the two
successful Dev runs or from the artifact inspection.

See [the acceptance procedure](../../domains/production-pairing-acceptance.md)
for evidence requirements and the laboratory/distribution limitations. No
complete automatic iOS promotion gate exists in this change.
