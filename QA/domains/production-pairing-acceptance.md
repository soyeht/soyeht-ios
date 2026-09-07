# Pairing acceptance on distributed builds

**Current scope:** the IPA preflight below executes now. Physical tests and
release promotion are separate work. This document is not a completed release
gate, and a successful IPA inspection is not permission to publish.

The initial physical Dev runs on 2026-09-07 demonstrated a real phone authenticating
to a real Mac and operating its terminal. They did not demonstrate a TestFlight
installation, an upgrade retaining a customer's keychain, or a deliberately
configured Wi-Fi-only run. Passing them cannot fill those missing results. Later VPN-off discovery and app-relaunch
comparisons are recorded in the dated run report; they do not fill distribution
or upgrade coverage.

## Inspect the candidate that will be uploaded

Run against the **exported IPA**, after signing, not just the archive:

```sh
make qa-ios-export IOS_IPA=/path/to/export/Soyeht.ipa \
  IOS_DEVELOPMENT_APP=/path/to/archive/Products/Applications/Soyeht.app
```

The second input must be a real, valid development-signed app: it is the control
that must be refused as a distribution artifact. The command also damages copies
of the actual app/extension, removes a profile and changes the extension inventory;
each must be refused. Inputs
are read-only and damaged copies live in a private temporary directory. Missing
inputs or failed inspection stop the command.

The inspector verifies Apple-anchored signatures for the production team,
effective identifiers/entitlements, App Store profile shape, expiry, keychain
groups, extension versions and the two expected production extension identities.
Changing the app's extension composition requires an explicit acceptance-policy
update. Its JSON always keeps delivery `not_observed`
and pairing `not_measured`. It neither starts candidate code nor installs it.
This is a local preflight; App Store Connect validation remains necessary.

Keep the IPA digest, build log and clean source revision together. Do not infer
the source revision from the version string. Apple can process the upload, so
bind TestFlight observations to the App Store Connect **build record**, version
and build number read on the installed phone. Do not require installed bytes to
equal the upload's IPA digest. A locally installed development build of the same
revision is useful evidence, but has a different distribution channel.

## Observe history, actions and results

The operator drives the ordinary interface. A second observation records what
the phone, Mac and kernel did. Do not fabricate a successful run by setting
`pass=true` or filling a matrix from unit-test results.

For each run, retain locally:

1. Candidate identity and actual installed versions on both ends; device model,
   OS, locale and display/text size. Use lab aliases in shareable reports.
   Equal version strings do not identify builds. Where available, match loaded
   image UUIDs from device logs to the controlled artifacts. In Dev builds with
   a debug dylib, the main launcher UUID may be unchanged: identify the code
   image that actually emitted the relevant event, not just the launcher.
2. The observed initial state and how it was obtained. Reinstallation is not a
   keychain reset. A debug reset on Dev is a fixture, not an App Store clean
   installation. For upgrades, record old/new builds and stable public identity
   before/after; a boolean `present` proves presence, not identical identity.
3. Start/end times and the ordinary gestures taken, with failure to drive a
   gesture reported separately. Capture the comparison-code screens locally;
   opening a window that failed Accessibility cannot count as an executed step.
   Prepare and identify the candidate, arm the collectors and observe readiness,
   then drive. Wait for the driver to finish within a bounded timeout before
   finalizing the logs, preserving the observed start time. A later
   `log collect --last 5m` can exclude an
   earlier action; a file named NEW can contain only the end of the OLD attempt.
   Match timestamps to the actual action, and report lost events as missing.
4. Phone and Mac subjects matched across credential issuance, authenticated
   presence and pane attach. A matching pair belonging to another device cannot
   satisfy the run. Keep raw logs local; publish no secrets, codes or terminal
   contents. Export only relevant diagnostic events with identifiers redacted.
5. A fresh random command challenge: first establish that its output file does
   not exist, type the command through the phone, then read the exact nonce from
   the Mac. Existence alone and an old marker are insufficient. Observation of
   the file alone does not prove the origin of the command; retain the gesture
   record as well.
6. For reconnect, close/reopen the phone app, repeat with another fresh nonce,
   and compare pane/session instance and shell PID/start if claiming continuity.
   Equal session counts do not prove the original sessions survived.

Do not require an actively used household directory to stay byte-identical as a
substitute for inspecting what changed. An unrelated legitimate write is neither
a pairing failure nor proof that pairing wrote the household. A final absent
household session does not by itself exclude a transient write during the run.

## Required coverage before broad distribution of a pairing change

Each applicable row needs its own observed result. `NOT RUN`, `UNKNOWN`, a failed
driver, or unavailable hardware cannot be treated as a pass. Link the evidence
and name the exact artifact/channel; do not transfer a Dev result to TestFlight.

| Case | What must be observed |
| --- | --- |
| Regression reproduction | Old and corrected iOS builds run on the same physical lab and observed starting conditions. The old build must exercise the reported failure, not merely fail to install or drive. A successful old run means the fixture has not reproduced the regression. |
| Fresh phone, existing home, owner unable to approve | Mac-local confirmation reaches a usable terminal without silently enrolling the phone in the home. |
| First home setup | The original setup and intended ownership still complete; the Mac-local fix must not replace first-owner setup. |
| Upgrade from the previously distributed iOS app | No uninstall/reset between builds; identity and usable pairing survive or the app offers the required explicit recovery. |
| Wi-Fi without Tailscale | Tailscale actually off, network permission state known, and the connection/terminal observed. A `.local` name alone does not establish the route. |
| Supported remote connection | The phone is actually outside the Mac's LAN and the supported route is observed. An address offered in a claim is not the terminal's chosen route. |
| Interrupted connection | While unavailable the app gives an actionable bounded state; after restoration it reconnects and accepts a new command without losing a live session. |
| Revoked credentials / mismatched versions | Access remains refused and the UI identifies recovery; no indefinite spinner or silent authority change. |
| Distribution | Candidate installed through TestFlight, with the public Mac package; verify the processed build identity on the phone. A cable sideload does not satisfy this row. |
| Supported environments | Oldest supported and current OS generations, more than one phone size, large text and at least a non-English locale; record any unsupported or untested combination explicitly. |

These are bounded acceptance cases, not a claim that every network or device in
the world will work. The public promise must state supported conditions and make
failures understandable. Simulator coverage supplements physical behavior; it
does not satisfy the distribution row.

## Available laboratory and release decision

As observed on 2026-09-07, the dedicated laboratory has one physical iPhone and
one Mac sharing the user's working host. Dev isolates app storage, credentials
and ports. A second macOS account on this host does **not** isolate TCP ports of
a clean production installation. A second Mac or a separately networked macOS
guest is needed for that exercise; a guest also has its own hardware limits.

Use authorized personal-device observations only for the particular history
they exercise. They do not replace the independent laboratory or distribution
coverage. Never reset a customer's phone or household to make a test easier.

Private TestFlight upload and broad public distribution are different decisions:
the candidate has to reach the private group before TestFlight usage can be
measured. Public promotion waits for the applicable coverage above, review of
failures and agreement on supported conditions. Expand to a small test group
with different devices/networks before broad promotion. Monitor pairing stages,
completion and recovery without collecting terminal contents.

There is currently no repository iOS upload/promotion entrypoint enforcing these
physical results. Do not describe this document or `qa-ios-export` as such an
enforcement mechanism. Add enforcement at the actual entrypoint once the
authorized distribution path and measured evidence format exist; test that a
missing/refused result prevents that entrypoint from publishing.
