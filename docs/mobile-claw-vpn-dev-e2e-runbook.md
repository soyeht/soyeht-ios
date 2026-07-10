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

## Owner-Present E2E Shape

After the preflight and status-aware runner are green, a fresh owner request is
prepared, and the owner is physically present with Device-D unlocked:

1. Build and install `Soyeht Dev` with normal development signing for
   `com.soyeht.app.dev`.
2. Ensure Device-D is paired to the DEV Engine context that can reach Mesh-C.
3. Ensure the backend DEV side has Device-D enrolled and authorized to access
   the target Claw-M or Claw-L.
4. Ensure Relay-R is configured only in DEV backend configuration. Do not place
   the relay endpoint in iOS source, tests, screenshots, or PR text.
5. Launch `Soyeht Dev` with the control-plane flag and private Device-D/Claw
   launch args.
6. In Settings, verify the Mobile Claw VPN row appears, the config state is
   `Configured`, and tap `Authorize`.
7. Expected DEV result today:
   - success: `Control-plane authorized`, with count/status-only UI;
   - fail-closed: `Failed`, with no token, endpoint, ID, or error echo.

The UI must never render raw Device-D/Claw IDs, rendezvous tokens, relay
endpoints, hostnames, or production-active success. If `productionActivation`
ever arrives as `true`, the ViewModel must publish a retryable failure.

## Sanitized Evidence

Public evidence may include only:

- commit SHA and build identifier;
- `Device-D`, `Claw-M` or `Claw-L`, `Relay-R`, `Mesh-C` aliases;
- the preflight status and sanitized run id;
- whether the Settings row was visible behind the DEV flag;
- whether the final state was `Control-plane authorized` or `Failed`;
- CI/test command names and pass/fail status.

Raw evidence must remain private:

- app launch arguments;
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
