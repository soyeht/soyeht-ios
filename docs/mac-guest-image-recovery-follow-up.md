# Follow-up: SoyehtMac guest-image failure-code recovery (Mac parity)

**Status:** open — deliberately deferred from PR-C (iPhone-only). Tracked here so
Mac parity is **visible and guarded**, not silently divergent.

## Context

PR-C ("iOS guided recovery UX consuming `guest_image_failure_code`") makes the
**iPhone** Claw Store render reason-coded recovery copy for macOS guest-image
preparation failures (theyos PR #89 `guest_image_failure_code`), keying the
**recovery action** off `GuestImageFailureCode.recoveryAction` (SoyehtCore) and
the **copy** off `GuestImageFailureCopy` (iOS app layer). Raw daemon/`VZErrorDomain`
text is never a primary line — it sits behind a "Details" disclosure.

## Why Mac is not in PR-C

SoyehtMac currently consumes `guestImageReadiness` **nowhere**. The Mac Claw Store
surfaces (`MacClawStoreRootView`, `MacClawDetailView`, `ClawDrawerViewController`)
gate purely on `installState`, and the Mac Welcome/Bootstrap flow has no
remote-prepare/readiness wiring. The remote-prepare flow is iPhone-driven by
design, so the recovery UX belongs on iPhone first. Adding it to the Mac is a
**from-scratch readiness integration**, not a field addition — out of scope for a
focused iPhone PR.

## What Mac parity must do (when implemented)

1. Consume `BootstrapStatusResponse.guestImageReadiness` (the SSoT, already in
   SoyehtCore) on the Mac Claw Store surfaces — same gate the iPhone uses.
2. Render `GuestImageReadiness.failed(error:code:)` with reason-coded recovery,
   reusing the domain `GuestImageFailureCode.recoveryAction`. Promote the copy
   (`GuestImageFailureCopy`, currently in the iOS app target) to a shared
   presentation module so the Mac can reuse it instead of duplicating strings.
3. Honor the same action rules: `host_vm_limit_reached` → "Check Again"
   (status refresh, **never** a prepare retry into a blocked host); raw engine
   text behind a disclosure; no button that a known code will make fail.
4. Add the SoyehtMac **source-slice guard** (the sibling of
   `LegacyBoundaryUsageTests.test_guestImageRecovery_isReasonCoded_noRawStringPrimary`)
   that fails if any Mac Claw Store surface renders a guest-image error without
   going through `GuestImageFailureCode` — this guard ships **with** the Mac
   implementation, not before it (there is nothing to guard until the Mac
   consumes the field).

## Apple-grade rationale

A pretty iPhone recovery flow with a Mac that still shows divergent/raw state is
not acceptable long-term. This doc + the iOS guard keep the gap explicit until
the Mac PR closes it.
