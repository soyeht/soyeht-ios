# QA Report: <Suite Name>

**Date**: YYYY-MM-DD
**Tester**: Automated via <tool> [+ Manual]
**Device**: iPhone <qa-device> (iOS 18.5)
**App**: com.soyeht.app (<build info>)
**Backend**: <server name(s)> (commit: <hash>)
**Plan Reference**: QA/domains/<domain>.md

---

## Executive Summary

**X test cases planned, Y executed, Z skipped.**
**Result: A/Y PASS, B/Y FAIL (C% pass rate)**

<1-3 sentence summary of findings>

---

## Test Results

### <Phase/Domain Name> (X/Y PASS)

| ID | Description | Status | Notes |
|----|-------------|--------|-------|
| ST-Q-XXX-001 | <test description> | PASS/FAIL/SKIP | <evidence or explanation> |

---

## Bugs Found

### BUG-XXX: <title> [Severity: P0/P1/P2/P3]

**Steps**: <repro steps>
**Expected**: <expected>
**Actual**: <actual>
**Screenshot**: `<filename>`
**Location**: `<file>:<line>`

---

## Gate Verdict

| Category | Result |
|----------|--------|
| Unit Tests | PASS/FAIL (X/Y) |
| API Contract | PASS/FAIL (X/Y) |
| UI Smoke | PASS/FAIL (X/Y) |
| **Overall** | **PASS / BLOCKED** |

---

## Cleanup

- [ ] `test-qa-*` instances deleted
- [ ] No leftover test data

## Test Artifacts

Screenshots saved to: `QA/runs/YYYY-MM-DD/screenshots/`
