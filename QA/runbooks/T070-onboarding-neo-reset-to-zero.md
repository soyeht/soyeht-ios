# T070 — Reset both Dev apps to zero before an onboarding run

**Goal**: put the Dev Mac and the Dev iPhone back to the state a brand new
machine and a brand new phone are in, so the onboarding flow can be judged as a
first-time owner sees it.

**Never touched by this procedure**: `/Applications/Soyeht.app`, its engine
(`com.soyeht.engine`, admin 8892, household 8091), its keychain namespaces and
its preference domain. Every step below is scoped to the Dev build
(`com.soyeht.mac.dev`, engine `com.soyeht.engine.dev`, household port 8101).

## Mac — one command

```bash
osascript -e 'quit app id "com.soyeht.mac.dev"'
SOYEHT_RUN_DEV_LOCAL_STATE_RESET=1 \
  "/Applications/Soyeht Dev.app/Contents/MacOS/Soyeht Dev" --reset-local-state-for-qa
```

The app launches, resets, and exits. Watch it work with:

```bash
log stream --predicate 'eventMessage CONTAINS "[DevLocalStateReset]"' --style compact
```

Expected lines: `stage=begin profile=dev`, `stage=files removed=<n> of=<m>`,
`stage=done domain=com.soyeht.mac.dev`. Exit code 2 with `refused reason=…`
means a Dev signal disagreed — most often the binary was the shipping app, or
the launch argument was dropped by the shell.

What it deletes: the `SoyehtDev` support directory (engine, databases,
`household-state/`, conversations, snapshots), `~/.theyos-dev`, the Dev
LaunchAgent registration, Dev logs and caches, every paired server and paired
iPhone, the household session with its Secure Enclave keys and the revocation
list, the Dev keychain services, and the `com.soyeht.mac.dev` preference domain
(which is what makes the Welcome window appear again).

What it deliberately does not delete: TCC grants (Accessibility, Screen
Recording, Local Network) — a reset that made the owner re-grant those would
change what we are measuring — and MCP configuration files, which are shared
with other agents on the machine.

Reinstall afterwards:

```bash
SOYEHT_DEV_DERIVED_DATA=/private/tmp/soyeht-dev-dd scripts/build-install-soyeht-dev
```

### If the command cannot run (older build, engine wedged)

```bash
launchctl bootout gui/$(id -u)/com.soyeht.engine.dev
rm -rf ~/Library/Application\ Support/SoyehtDev ~/.theyos-dev \
       ~/Library/Logs/SoyehtDev ~/Library/Caches/SoyehtDev ~/.cache/theyos-dev \
       /tmp/soyehtdev-* ~/Library/LaunchAgents/com.soyeht.engine.dev.plist
defaults delete com.soyeht.mac.dev
```

Keychain items live under the Dev services `com.soyeht.mac.dev`,
`com.soyeht.mobile.dev` and `com.soyeht.household.dev`; delete them from
Keychain Access, or let the reset command above do it. Never run
`scripts/uninstall-soyeht-macos-keychain.swift` for a Dev reset — it is
release-only and says so.

## iPhone — reset then reinstall

1. Open the debug reset URL in the Dev app:
   `soyeht://debug/reset-local-state`. From the Mac:
   ```bash
   xcrun devicectl device process launch --device "$SOYEHT_IOS_DEVICE_UDID" \
     --payload-url "soyeht://debug/reset-local-state" com.soyeht.app.dev
   ```
   (In a DEBUG build the URL needs no arming from Settings.)
2. Delete the app from the Home screen. This is what clears the keychain items
   the reset URL cannot reach.
3. Reinstall:
   ```bash
   xcodebuild -project TerminalApp/Soyeht.xcodeproj -scheme "Soyeht Dev" \
     -configuration Dev -destination "$SOYEHT_IOS_DEVICE_DESTINATION" \
     -skipPackagePluginValidation build
   xcrun devicectl device install app --device "$SOYEHT_IOS_DEVICE_UDID" \
     "<DerivedData>/Build/Products/Dev-iphoneos/Soyeht.app"
   ```

Keep the device identifier in the environment; it never goes in a commit.

## Proof that zero really is zero

| Check | Command | Expected |
|---|---|---|
| No Dev engine running | `launchctl print gui/$(id -u)/com.soyeht.engine.dev` | `Could not find service` |
| No Dev state on disk | `ls ~/Library/Application\ Support/SoyehtDev` | no such directory |
| No Dev defaults | `defaults read com.soyeht.mac.dev` | domain does not exist |
| Shipping install untouched | `launchctl print gui/$(id -u)/com.soyeht.engine \| head -3` | still loaded |
| Mac opens onboarding | launch `Soyeht Dev.app` | Welcome window, first step |
| iPhone opens onboarding | launch `Soyeht Dev` | first onboarding screen, no home |

## Operator log

| Date | Operator | Slice under test | Mac reset OK? | iPhone reset OK? | Notes |
|------|----------|------------------|---------------|------------------|-------|
|      |          |                  |               |                  |       |
