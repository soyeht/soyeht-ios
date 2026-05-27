# theyos-engine version — single source of truth

> If you are an agent (Claude Code, Codex, OpenCode, …) and you got here
> because the iPhone client failed to talk to a Mac with a "wrong content
> type" / 404 / "couldn't add this Mac" error, **read this whole file**.
> It is short on purpose.

## What this is

`Soyeht.app` (the Mac app in this repo) bundles a Rust binary called
`theyos-engine` that lives in a **separate repo** (`soyeht/theyos`). The
binary is downloaded from a GitHub Release by `scripts/fetch-engine.sh`
and embedded into the .app at build time by `scripts/embed-engine.sh`.

The engine version is pinned in **one place**:

```
scripts/theyos-engine.version
```

Format: a single semver string (no `v` prefix), with optional `#`-prefixed
comments. The matching SHA-256 must exist in `scripts/theyos-engine.sha256`.

## Apple-style: pin per release, not "always latest"

Every `Soyeht.app` release ships with an exact engine version stamped in.
Two devs building the same commit always get the same binary. Reproducible
by construction. We never auto-fetch "latest" at build time — that would
introduce non-determinism and break trust in the supply chain.

## When TO bump

Bump the pin when **any** of these is true:

1. **iOS client adds a new endpoint** (e.g. a new `Bootstrap*Client`) and
   the running engine versions in the field don't yet expose it. Symptom
   in production: `BootstrapProtocolViolationDetail.unexpectedResponseShape`
   or `wrongContentType` from `JoinRequestStagingClient` /
   `BootstrapAcceptHouseholdClient` / `BootstrapAcceptHouseholdConfirmClient`.

2. **iOS client switches wire format** (e.g. JSON → CBOR) and the engine
   currently bundled still speaks the old format.

3. **Engine ships a bug fix** the iOS client now depends on (deadlock,
   crash on rename, missing field, …).

4. **You are cutting a Soyeht.app release** — sanity-check the pin against
   the latest theyos release before tagging, even if you didn't see a
   protocol break this cycle.

## When NOT to bump

- "Just to be on latest" without a concrete reason from the list above.
- "It looks scary to be 3 versions behind" — being behind is fine if every
  endpoint the iOS client uses works against the pinned version.
- Mid-PR for an unrelated feature. Engine bumps belong in their own commit
  so the change is easy to revert if e2e regresses.

## How to bump (concrete steps)

1. **Find the target version** on GitHub:
   ```
   gh release list --repo soyeht/theyos --limit 10
   ```

2. **Verify compatibility** with the iOS client. Read the release notes:
   ```
   gh release view vX.Y.Z --repo soyeht/theyos
   ```
   Look for breaking changes, new endpoints the iOS client now needs, or
   removed endpoints the iOS client still calls.

3. **Compute the new SHA-256**:
   ```
   curl -sSL -o /tmp/theyos.tgz \
     https://github.com/soyeht/theyos/releases/download/vX.Y.Z/theyos-engine-X.Y.Z-macos-arm64.tar.gz
   shasum -a 256 /tmp/theyos.tgz
   ```

4. **Edit two files**:
   - `scripts/theyos-engine.version` → set to `X.Y.Z`
   - `scripts/theyos-engine.sha256` → append `X.Y.Z  <sha>`

5. **Re-fetch + verify**:
   ```
   rm -rf /tmp/theyos-engine-dist
   bash scripts/fetch-engine.sh
   /tmp/theyos-engine-dist/theyos-engine --version
   ```
   Output must match `X.Y.Z`.

6. **E2E test** by rebuilding the DMG and pairing a Mac to an iPhone in
   the failing scenario (the one that motivated the bump).

7. **Commit** with subject `Bump theyos-engine to X.Y.Z` and a body that
   names the iOS-side rationale (new endpoint? wire change? bug fix?).

## How to override locally (dev only)

You don't need to touch the manifest to try a different engine version on
your machine. Override via env var:

```
ENGINE_VERSION=0.1.17 bash scripts/fetch-engine.sh
```

CI and release pipelines must NOT set this env var — they always use the
pinned manifest. That's how reproducibility is preserved.

## Anti-patterns we explicitly reject

- "Always use `gh release view --repo soyeht/theyos --latest`" inside the
  build. Reason: non-reproducible builds, breaks SHA-256 supply-chain trust.
- Hard-coding the version literal inside `fetch-engine.sh`. Reason: split
  brain between script and SHA file; agents bump one and forget the other.
- Skipping the SHA-256 pin "to make CI faster". Reason: this is the only
  supply-chain check we have for the engine binary.

## Files involved

| File | Role |
| ---- | ---- |
| `scripts/theyos-engine.version` | THE pin (single source of truth) |
| `scripts/theyos-engine.sha256` | Pinned SHA-256 per version |
| `scripts/fetch-engine.sh`      | Reads the pin, downloads tarball, verifies SHA |
| `scripts/embed-engine.sh`      | Copies the binary into `Soyeht.app/Contents/Helpers/` |
| `scripts/build-dmg.sh`         | Calls the above during release |
