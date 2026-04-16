# QA Report: File Browser + Live Watch

**Date**: 2026-04-16
**Tester**: Automated via Appium + backend helpers
**Device**: iPhone <qa-device> (iOS 26.4.1)
**App**: com.soyeht.app
**Backend**: https://<host>.<tailnet>.ts.net (zeroclaw-qa-caio-0415/31b0b16356b43cf0)
**Plan Reference**: QA/domains/file-browser.md + QA/domains/live-watch.md

## Executive Summary

**25 test cases executed.**
**Result: 23 PASS, 2 FAIL, 0 SKIP**

## Test Results

| ID | Status | Notes |
|----|--------|-------|
| ST-Q-BROW-001 | PASS | Browser opens from keybar with list and breadcrumb |
| ST-Q-BROW-003 | PASS | Subfolder navigation updates list and breadcrumb |
| ST-Q-BROW-004 | PASS | Breadcrumb segment navigates up to Downloads |
| ST-Q-BROW-005 | PASS | Root breadcrumb jumps directly to root |
| ST-Q-BROW-007 | PASS | Agent-created Reports folder appears normally |
| ST-Q-BROW-006 | PASS | All five favorite chips are visible |
| ST-Q-BROW-008 | PASS | Markdown preview opens with action buttons |
| ST-Q-BROW-009 | PASS | Plain text preview opens for .log |
| ST-Q-BROW-010 | PASS | Plain text preview opens for .swift/.json/.sh |
| ST-Q-BROW-011 | PASS | PDF opens in-app via Quick Look child |
| ST-Q-BROW-012 | PASS | Video preview/download flow is reachable in-app |
| ST-Q-BROW-013 | PASS | Image opens in-app via Quick Look child |
| ST-Q-BROW-014 | PASS | Unsupported file shows preview alert |
| ST-Q-BROW-015 | PASS | Large text file limit enforced |
| ST-Q-BROW-016 | FAIL | File list exposes metadata subtitle content |
| ST-Q-BROW-017 | PASS | Pull-to-refresh reloads list and shows footer |
| ST-Q-BROW-018 | PASS | Save to iPhone shows Saved toast |
| ST-Q-BROW-020 | PASS | Save As opens document picker |
| ST-Q-BROW-021 | PASS | Share button opens activity controller |
| ST-Q-BROW-019 | PASS | Saved file remains available in app container for offline access |
| ST-Q-BROW-022 | PASS | Long-press file row can share remote path |
| ST-Q-BROW-023 | FAIL | Large video shows inline download progress without premature preview |
| ST-Q-BROW-024 | PASS | Cancel returns row to normal state |
| ST-Q-BROW-025 | PASS | Missing remote file renders inline retry state after failed download |
| ST-Q-BROW-025 | PASS | Retry restarts the download flow after restoring the file |
