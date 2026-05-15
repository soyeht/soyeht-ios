# QA Report: File Browser + Live Watch

**Date**: 2026-04-16
**Tester**: Automated via Appium + backend helpers
**Device**: iPhone <qa-device> (iOS 26.4.1)
**App**: com.soyeht.app
**Backend**: https://<host>.<tailnet>.ts.net (zeroclaw-qa-caio-0415/31b0b16356b43cf0)
**Plan Reference**: QA/domains/file-browser.md + QA/domains/live-watch.md

## Executive Summary

**19 test cases executed.**
**Result: 11 PASS, 8 FAIL, 0 SKIP**

## Test Results

| ID | Status | Notes |
|----|--------|-------|
| ST-Q-LIVE-001 | PASS | Live Watch popover opens from breadcrumb badge |
| ST-Q-LIVE-002 | PASS | Initial snapshot populates popover |
| ST-Q-LIVE-004 | PASS | Live Watch appends marker text from pane stream |
| ST-Q-LIVE-005 | PASS | Pane stream appends many lines and reaches bottom |
| ST-Q-LIVE-008 | PASS | Open Full Screen presents viewer with text |
| ST-Q-LIVE-006 | FAIL | Background/foreground resumes stream and reloads snapshot |
| ST-Q-LIVE-009 | FAIL | Top button scrolls to beginning content |
| ST-Q-LIVE-010 | PASS | Bottom button scrolls to end content |
| ST-Q-LIVE-011 | FAIL | Copy copies live watch text to pasteboard |
| ST-Q-LIVE-012 | PASS | Share opens activity controller with text content |
| ST-Q-LIVE-013 | FAIL | Add to prompt injects text back into terminal |
| LIVE_014 | FAIL | Runner error: Unable to reach terminal screen from current app state |
| ST-Q-LIVE-015 | FAIL | Long press opens peek card |
| ST-Q-LIVE-021 | FAIL | Peek scanning state remains visible after drag |
| ST-Q-LIVE-017 | PASS | Extended press promotes peek to full-screen viewer |
| ST-Q-LIVE-018 | FAIL | Peek card updates while stream continues |
| ST-Q-LIVE-016 | PASS | Releasing/clearing long press collapses peek card |
| ST-Q-LIVE-019 | PASS | Popover header rendered; screenshot captured for pulse indicator |
| ST-Q-LIVE-020 | PASS | New stream content arrived while badge pulse evidence was captured |
