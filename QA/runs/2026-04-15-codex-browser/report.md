# QA Report: File Browser + Live Watch

**Date**: 2026-04-15
**Tester**: Automated via Appium + backend helpers
**Device**: iPhone <qa-device> (iOS 26.4.1)
**App**: com.soyeht.app
**Backend**: https://<host>.<tailnet>.ts.net (zeroclaw-qa-caio-0415/31b0b16356b43cf0)
**Plan Reference**: QA/domains/file-browser.md + QA/domains/live-watch.md

## Executive Summary

**2 test cases executed.**
**Result: 0 PASS, 2 FAIL, 0 SKIP**

## Test Results

| ID | Status | Notes |
|----|--------|-------|
| BROW_001 | FAIL | Runner error: Unable to find xpath=//*[@label='Move' or @name='folder']: 404 Client Error: Not Found for url: http://127.0.0.1:4723/session/df582fec-0e52-4430-a6d8-20fcf101ae5f/element |
| BROW_003_004_005_007 | FAIL | Runner error: Unable to find xpath=//*[@label='Move' or @name='folder']: 404 Client Error: Not Found for url: http://127.0.0.1:4723/session/df582fec-0e52-4430-a6d8-20fcf101ae5f/element |
