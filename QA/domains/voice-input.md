---
id: voice-input
ids: ST-Q-VOIC-001..007
profile: release
automation: manual
requires_device: true
requires_backend: mac
destructive: false
cleanup_required: false
---

# Voice Input

## Objective
Verify voice-to-text flow: dual permissions (microphone + speech recognition), recording, transcription, terminal insertion, and graceful degradation when permissions denied.

## Risk
AVAudioSession `.playAndRecord` + `.duckOthers` configuration can fail if another app holds audio session. If microphone granted but speech recognition isn't, recording starts but transcription silently fails.

## Preconditions
- Connected to an instance terminal
- Device microphone functional

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-VOIC-001 | Tap voice input button (first time) | Permission prompts for microphone AND speech recognition | P1 | Manual |
| ST-Q-VOIC-002 | Grant both permissions | Recording panel appears with waveform. Voice bar active | P1 | Manual |
| ST-Q-VOIC-003 | Speak a command (e.g., "ls minus la") | Transcribed text appears. Inserted into terminal on send | P1 | Manual |
| ST-Q-VOIC-004 | Start recording, then cancel | Recording stops. No text inserted. Terminal unchanged | P2 | Manual |
| ST-Q-VOIC-005 | Deny microphone permission (Settings) | Voice button shows denied state. Tapping shows guidance, no crash | P1 | Manual |
| ST-Q-VOIC-006 | Deny speech recognition only | Voice button shows denied. Clear message about which permission | P2 | Manual |
| ST-Q-VOIC-007 | After deny, re-enable in Settings, return | Voice input works again without app restart | P2 | Manual |
