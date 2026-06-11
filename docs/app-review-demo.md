# App Review Demo Host

Soyeht for iOS currently mirrors a live Soyeht macOS terminal. Apple App Review
must be able to test that flow without reaching a personal development machine.
Apple's review guidance asks for full access, and for account-based or
environment-dependent apps it allows a demo account, fully-featured demo mode,
sample QR code, or other required resources:

- https://developer.apple.com/app-store/review/guidelines/
- https://developer.apple.com/distribute/app-review/

The release-ready path is a disposable macOS review host:

1. Run Soyeht on a dedicated standard macOS user or disposable VM.
2. Keep that host free of personal files, source code, signing keys, production
   credentials, and developer tools that are not needed for the demo.
3. Start Soyeht with the App Review demo environment from
   `scripts/app-review-demo-host.sh`.
4. Provide App Review with the iOS test steps and, when needed, the pairing
   link/QR or public host information.

Do not use the Claw Store as the review workaround. Claw Store is intentionally
hidden/coming soon for this release; the review flow should exercise the
shipping iOS mirror feature.

## Security Boundary

`SOYEHT_APP_REVIEW_DEMO_ROOT` changes where local shell panes start:

- `HOME` becomes `<demo-root>/home`.
- `PWD` becomes `<demo-root>/workspace`.
- `PATH` is restricted to a known system/Homebrew path.
- Bash starts with the review `.bashrc`, not the real user's shell files.

This is a product/demo environment, not a sandbox. If the macOS process runs as
your personal user, the reviewer could still access files readable by that user
through normal Unix paths. The real boundary must be a dedicated macOS user,
VM, or other disposable host account.

## Setup

On the review host:

```bash
scripts/app-review-demo-host.sh \
  --app /Applications/Soyeht.app \
  --root "$HOME/SoyehtReviewDemo" \
  --mac-name "Soyeht Review Mac" \
  --confirm-disposable-host \
  --print-review-notes
```

For local validation on a developer machine only:

```bash
scripts/app-review-demo-host.sh \
  --dev \
  --root /tmp/soyeht-app-review-demo \
  --allow-current-user \
  --print-review-notes
```

To clear the launch environment later:

```bash
scripts/app-review-demo-host.sh --clear-launch-env
```

## Network

The iOS app needs to reach the macOS presence/attach endpoints. Preferred
review setup:

- Same Wi-Fi/LAN when the reviewer and host are colocated.
- A stable public route to the disposable host when review is remote.

Do not require the Apple reviewer to install Tailscale or any third-party VPN.
Tailscale is acceptable for our internal validation, but App Review notes should
provide a route the reviewer can use with the iOS app alone.

If using a public tunnel/reverse proxy, point it only at the disposable review
host and reset the pairing state after review.

## App Store Connect Review Notes Template

Paste and customize this in App Review Information:

```text
Soyeht iOS mirrors a live Soyeht macOS terminal. For review we are running a
disposable macOS demo host with no personal data.

Mac display name: Soyeht Review Mac
Reachability: <same LAN / public host / pairing link or QR>

Steps:
1. Open Soyeht on iPhone.
2. Select "Soyeht Review Mac" from the Mac list, or use the supplied pairing
   link/QR if the device is not on the same LAN.
3. Open the visible shell pane.
4. Run safe commands:
   pwd
   ls -la
   cat README.txt
   echo "Hello from Soyeht"
   date

The terminal starts in a disposable workspace. HOME points to the review demo
home directory and PWD points to the review demo workspace. No personal files or
developer secrets are present on this host.
```

## Reset

After review:

```bash
scripts/app-review-demo-host.sh --clear-launch-env
rm -rf "$HOME/SoyehtReviewDemo"
```

If the host was a VM snapshot, revert the snapshot instead.
