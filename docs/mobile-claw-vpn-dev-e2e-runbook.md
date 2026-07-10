# Mobile Claw VPN DEV Control-Plane E2E Runbook

Status: operator runbook for the Product A mobile Claw VPN DEV evidence gate.
This is not production activation, not NetworkExtension datapath validation, and
not approval to mutate host routes.

The iOS control-plane surface is default-off and DEV-gated. A green run here
proves only the Device-D control-plane path:

- the Dev app exposes the Settings control-plane surface only under the DEV
  bundle plus the explicit launch argument;
- Device-D can ask the paired Engine server to run the
  mint-offer -> consume-offer -> authorize-rendezvous sequence for a configured
  Claw;
- the iOS state remains count/status-only and fails closed if the server reports
  production activation;
- raw IDs, tokens, relay endpoints, hostnames, and device identifiers stay in
  local-only evidence.

It does **not** prove PacketTunnel, TUN/utun routing, relay datapath forwarding,
production activation, or real host-networking mutation. Those remain separate
owner-present gates.

## Safety Rules

- Use only `Soyeht Dev` / bundle id `com.soyeht.app.dev`.
- Do not modify, quit, restart, overwrite, or inspect the installed shipping
  `/Applications/Soyeht.app`.
- Do not commit, paste, log, screenshot, or attach raw Device-D, Claw-M,
  Claw-L, Relay-R, Mesh-C, endpoint, token, hostname, IP, UDID, or account
  values.
- Public reports may use only aliases: `Device-D`, `Claw-M`, `Claw-L`,
  `Relay-R`, and `Mesh-C`.
- Store raw evidence under a user-owned private directory outside the
  repository. The parent must be mode `0700`; raw files should be mode `0600`.
- If a step needs a physical iPhone unlock, provisioning profile change,
  Apple/NetworkExtension account action, sudo, route mutation, or production
  decision, stop for owner-present action.

## Local Private Configuration

Put real values in an ignored local file, for example
`.env.mobile-claw-vpn.local`. Do not paste the file contents into chat, PRs, or
docs.

The preflight and runner load the first local config file found in this order:

1. `SOYEHT_MOBILE_CLAW_VPN_DEV_E2E_ENV_FILE`, if set in the shell;
2. `.env.mobile-claw-vpn.local`;
3. `.env.local`;
4. `.env`.

Shell environment values take precedence over file values. The loader reads only
the Mobile Claw VPN DEV E2E allowlisted keys; unknown keys are ignored, and the
file is not evaluated as shell code.

```sh
export SOYEHT_MOBILE_CLAW_VPN_EVIDENCE_DIR="$HOME/Library/Application Support/SoyehtDev/MobileClawVPN/Evidence"
export SOYEHT_MOBILE_CLAW_VPN_BUNDLE_ID="com.soyeht.app.dev"

# Physical Device-D selection for xcodebuild/devicectl. Values are private.
export SOYEHT_IOS_DEVICE_DESTINATION='platform=iOS,id=<device-id>'
export SOYEHT_IOS_DEVICE_ID='<device-id>'

# Control-plane IDs consumed by the DEV launch args. Values are private.
export SOYEHT_MOBILE_CLAW_VPN_DEVICE_ID='<device-d-id>'
export SOYEHT_MOBILE_CLAW_VPN_CLAW_ID='<claw-id>'

# Public aliases only. These are safe for sanitized summaries.
export SOYEHT_MOBILE_CLAW_VPN_DEVICE_ALIAS='Device-D'
export SOYEHT_MOBILE_CLAW_VPN_CLAW_ALIAS='Claw-M'
export SOYEHT_MOBILE_CLAW_VPN_RELAY_ALIAS='Relay-R'
export SOYEHT_MOBILE_CLAW_VPN_MESH_ALIAS='Mesh-C'
```

The app launch arguments for the DEV control-plane surface are:

```text
-SoyehtMobileClawVPNControlPlaneE2E
-SoyehtMobileClawVPNDeviceID <private Device-D id>
-SoyehtMobileClawVPNClawID <private Claw id>
```

The launch arguments are raw evidence because they contain private values. Keep
any `xcodebuild`, simulator, device, or screenshot artifacts local.

## Readiness Preflight

Run the preflight after exporting the private configuration:

```sh
SOYEHT_RUN_MOBILE_CLAW_VPN_DEV_E2E_PREFLIGHT=1 \
  scripts/mobile-claw-vpn-dev-e2e-preflight.sh
```

The preflight does not launch the app or contact a relay. It validates that:

- the evidence directory is outside the repository, user-owned, and mode `0700`;
- a physical Device-D destination was selected explicitly;
- private Device-D and Claw IDs are present;
- the bundle id is the DEV bundle;
- public summary aliases are from the approved alias set.

On success it prints and writes a sanitized JSON summary with aliases only. It
never prints the private Device-D id, Claw id, device UDID, endpoint, token, or
hostname. If the script returns `skipped` or `refused`, treat the E2E evidence
as missing.

## Status-Aware Owner-Present Gate

The optional runner consumes the preflight JSON and refuses to treat exit code
`0` as readiness by itself:

```sh
SOYEHT_RUN_MOBILE_CLAW_VPN_DEV_E2E=1 \
  scripts/mobile-claw-vpn-dev-e2e-runner.sh
```

The runner still does not launch the app, contact Relay-R, open a socket, or
mutate host networking. It requires the preflight payload to be
`status == "ready"` with `summary_written == true`, verifies the private
evidence directory and preflight summary permissions, then writes a sanitized
`mobile-claw-vpn-dev-e2e-runner-summary.json` with:

- `status: "ready_for_owner_present"`;
- a fresh `run_id` that matches the private runner summary;
- `owner_present_required: true`;
- `app_launch_attempted: false`;
- `relay_contact_attempted: false`;
- `raw_values_printed: false`.

If the preflight returns `skipped` or `refused`, the runner emits a sanitized
`preflight_not_ready` result. Future E2E automation must gate on
`status == "ready_for_owner_present"` before asking the owner to run the real
device flow.

## Fresh Owner-Confirmation Request

Readiness is not authorization to launch the app. The owner-request tool turns
one fresh runner result into a short-lived request carrying the merged code,
readiness, and Device-D bindings needed for a future owner confirmation. The
request is context only: it does not prove owner presence or authorize any
execution.

Prepare a request:

```sh
SOYEHT_PREPARE_MOBILE_CLAW_VPN_DEV_E2E_OWNER_REQUEST=1 \
  scripts/mobile-claw-vpn-dev-e2e-owner-request.sh
```

The command reruns the status-aware runner, requires its stdout and `0600`
summary to carry the same fresh `run_id`, binds the request to the merged clean
`origin/main` SHA and the explicit Device-D selection, and writes a private
request that expires after five minutes. The output and request always report
`owner_acknowledged=false`, `execution_authorized=false`,
`app_launch_attempted=false`, and `relay_contact_attempted=false`.

The request opt-in is intentionally **not** accepted by the local env-file
loader. More importantly, the request, its `attempt_id`, readiness status, and
exit code are never permission to install or launch anything. This slice has no
acknowledgment or execution path. A future physical-device executor must obtain
a distinct owner-originated confirmation at the point of use, revalidate all
bindings, and atomically consume the request before its first app effect. The
request tool does not run `xcodebuild`, `devicectl`, the app, a relay,
NetworkExtension, or host networking.

## Local Biometric Presence Primitive

The request above is still not authority. The future executor may use a fresh
local biometric gesture as one input to the DEV-only point-of-use gate. This is
strictly a **local biometric presence** signal; it does not authenticate the
Soyeht household owner and must never be reported as `owner_authenticated` or
`execution_authorized`.

`scripts/mobile-claw-vpn-dev-local-presence.swift` defines the helper used by
that future executor. It is intentionally not wrapped as a standalone operator
command and does not read local env files. The executor must:

- compile the helper before the gesture and include the exact source and binary
  digests in the immutable execution manifest;
- re-hash the fixed binary immediately before spawning it;
- generate the execution run id and replay nonce itself;
- send one canonical challenge through the child's stdin, never by path, argv,
  environment variable, or reusable file;
- read the response only from the pipe belonging to that child invocation;
- require the returned challenge digest and execution run id to match its
  in-memory tuple;
- revalidate the request, readiness, repository, manifest, and Device-D after
  the gesture, then atomically consume the request before the first effect.

The helper decodes the stdin bytes once, validates a maximum two-minute TTL,
shows only the approved aliases and short source/run hashes, and signs the exact
challenge digest with a process-local Secure Enclave P-256 key protected by
`biometryCurrentSet` and private-key usage. It uses a new `LAContext`, disables
authentication reuse, invalidates the context at the end, does not export a key
reference or signature, and revalidates expiry after the gesture. It writes no
anchor, proof, result, or authority file.

Successful output is correlation-only and includes
`local_biometric_presence_observed=true`, the challenge digest, and execution
run id. It always includes `owner_authenticated=false`,
`execution_authorized=false`, `app_launch_attempted=false`, and
`raw_values_printed=false`. The output is not replayable authority and must not
be stored for a later run. Cancel, lockout, missing biometry, Secure Enclave
unavailability, malformed input, mismatch, or expiry all stop before any app or
device effect.

CI compiles the production shape and runs only a software-key codec/binding
self-test. CI does not claim biometric presence. Before an executor can receive
GO for a physical run, a manual DEV check must prove that each invocation asks
for Touch ID, cancellation fails, a second invocation requires a fresh gesture,
and no authority artifact remains.

This local signal does not prove Device-D identity, paired Engine identity or
artifact SHA, Relay-R contact, NetworkExtension, TUN/utun, routing, forwarding,
or production activation. A remote, durable, household-owner, or production
authorization requires the separate OwnerApprovalV2/passkey trust path.

## Owner-Present E2E Shape

After the preflight and status-aware runner are green, a fresh owner request is
prepared, and the owner is physically present with Device-D unlocked:

1. Build `Soyeht Dev`, `SoyehtTests`, the generated xctestrun, and the local
   presence helper before the biometric gesture. Freeze their hashes in one
   private execution manifest; do not rebuild after the gesture.
2. Create a fresh owner request, validate Device-D, observe local biometric
   presence through the exact manifest-bound helper, then revalidate every
   binding and consume the request with a durable create-new claim.
3. Only after the claim, install the manifest-bound Dev app. Copy exactly one
   private `input.json` into the app container's `MobileClawVPNDevE2E`
   directory. Do not put private IDs in xctestrun environment variables,
   launch arguments, test names, or command lines.
4. Run only
   `SoyehtTests/MobileClawVPNOwnerPresentProbeTests/testRunOwnerPresentControlPlane`.
   The app-hosted test consumes and unlinks the input before calling the public
   default `MobileClawVPNRendezvousViewModel`, which drives the production
   ViewModel -> Authorizer -> API client sequence.
5. Download only the run-scoped sanitized result from the same Dev bundle and
   Device-D. Success requires the expected XCTest to pass exactly once and the
   result to match the in-memory execution tuple, manifest, claim, and run id.

The probe result contains only aliases, hashes, booleans, and status counts. It
never contains Device-D/Claw IDs, offer or rendezvous tokens, endpoint, host,
URL, or raw errors. A failed or production-active authorization cannot produce
`control_plane_sequence_completed=true`.

This test proves the Dev app's production control-plane composition reached its
paired host and completed the validated mint -> consume -> authorize sequence.
It does not independently attest a specific Engine artifact and does not prove
Relay-R contact, relay pairing/splice, NetworkExtension, tunnel establishment,
packet forwarding, TUN/utun, route, DNS, or host mutation. Relay contact must be
reported as unknown unless authoritative backend evidence is collected.

## Sanitized Evidence

Public evidence may include only:

- commit SHA and build identifier;
- `Device-D`, `Claw-M` or `Claw-L`, `Relay-R`, `Mesh-C` aliases;
- the preflight status and sanitized execution run id;
- whether the exact app-hosted XCTest ran once and passed or failed;
- `control_plane_sequence_completed`, `authorized`, snapshot presence, and the
  five status counts from the sanitized run-scoped result;
- relay contact as `unknown` unless authoritative backend evidence exists;
- CI/test command names and pass/fail status.

Raw evidence must remain private:

- the private input and result files in the Dev app container;
- generated xctestrun and DerivedData;
- `.xcresult` bundles and xcodebuild stdout/stderr;
- devicectl stdout/stderr and copy/install logs;
- device IDs/UDIDs;
- Device-D/Claw IDs;
- relay endpoints;
- hostnames/IPs;
- tokens;
- raw network logs;
- screenshots showing any private infrastructure value.

## Failure Handling

- Missing or invalid local config: fix the ignored `.env.*.local` file and
  rerun the preflight.
- Preflight reports a repo path or non-owned evidence dir: choose a private
  directory outside the repository.
- `Soyeht Dev` profile or signing failure: fix provisioning for the DEV bundle.
  Do not use a production bundle as a workaround.
- Authorization failure: keep raw logs private and report only the sanitized
  failure class. Do not retry by exposing tokens or endpoints in UI/log output.
- Any accidental disclosure of raw values: stop, remove the leaked material, and
  rotate/reissue affected credentials before collecting new evidence.
