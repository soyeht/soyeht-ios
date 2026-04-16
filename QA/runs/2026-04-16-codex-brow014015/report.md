# QA Report: File Browser + Live Watch

**Date**: 2026-04-16
**Tester**: Automated via Appium + backend helpers
**Device**: iPhone <qa-device> (iOS 26.4.1)
**App**: com.soyeht.app
**Backend**: https://<host>.<tailnet>.ts.net (zeroclaw-qa-caio-0415/31b0b16356b43cf0)
**Plan Reference**: QA/domains/file-browser.md + QA/domains/live-watch.md

## Executive Summary

**1 test cases executed.**
**Result: 0 PASS, 1 FAIL, 0 SKIP**

## Test Results

| ID | Status | Notes |
|----|--------|-------|
| BROW_014_015 | FAIL | Runner error: Unable to find accessibility id=soyeht.fileBrowser.row./root/Downloads/unsupported.bin: 404 Client Error: Not Found for url: http://127.0.0.1:4723/session/cffdc9b8-5b02-4898-85b0-2d7126ea550f/element |
