# QA Report: File Browser + Live Watch

**Date**: 2026-04-16
**Tester**: Automated via Appium + backend helpers
**Device**: iPhone <qa-device> (iOS 26.4.1)
**App**: com.soyeht.app
**Backend**: https://<host>.<tailnet>.ts.net (zeroclaw-qa-caio-0415/31b0b16356b43cf0)
**Plan Reference**: QA/domains/file-browser.md + QA/domains/live-watch.md

## Executive Summary

**4 test cases executed.**
**Result: 0 PASS, 4 FAIL, 0 SKIP**

## Test Results

| ID | Status | Notes |
|----|--------|-------|
| ST-Q-LIVE-006 | FAIL | Background/foreground resumes stream and reloads snapshot |
| LIVE_009_010_011_012_013 | FAIL | Runner error: Unable to find accessibility id=soyeht.diff.previousButton: 404 Client Error: Not Found for url: http://127.0.0.1:4723/session/5e9e7226-1e04-4f63-9a4f-d57561e36008/element |
| ST-Q-LIVE-014 | FAIL | Unable to force app into mirror mode |
| LIVE_015_016_017_018_021 | FAIL | Runner error: Unable to find accessibility id=soyeht.liveWatch.list: 404 Client Error: Not Found for url: http://127.0.0.1:4723/session/5e9e7226-1e04-4f63-9a4f-d57561e36008/element |
