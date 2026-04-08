---
id: error-handling
ids: ST-Q-ERR-001..004
profile: standard
automation: assisted
requires_device: true
requires_backend: mac
destructive: false
cleanup_required: false
---

# Error Handling

## Objective
Verify graceful handling of network errors, 404s, and 403s after API format changes.

## Risk
Error responses changed format. If error body parsing fails, app may crash instead of showing error message.

## Preconditions
- Connected to server with active instance

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-ERR-001 | Turn off WiFi, try to load instances | Error message (not crash). Pull-to-refresh or retry available | P0 | Assisted (WiFi toggle) |
| ST-Q-ERR-002 | Turn WiFi back on, retry | Instances load normally | P1 | Assisted |
| ST-Q-ERR-003 | Access instance deleted from another device | 404 handled gracefully (error message, not crash) | P1 | Yes |
| ST-Q-ERR-004 | Try admin action as non-admin | 403 shown as "Forbidden" or similar. No crash | P2 | Yes |
