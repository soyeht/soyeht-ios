---
id: file-browser
ids: ST-Q-BROW-001..028
profile: full
automation: assisted
requires_device: true
requires_backend: mac
destructive: false
cleanup_required: false
---

# File Browser

## Objective
Verify the remote file browser flow end-to-end: opening from the keybar into the active tmux pane directory, navigating remote folders, previewing files in-app, downloading to iPhone, sharing, and seeing download progress/errors. Covers US-1 through US-8.

## Risk
The browser fetches the initial path from `GET /tmux/cwd` — if that call fails or returns a malformed pane_id the breadcrumb git button will be hidden and Live Watch unreachable. Remote file preview silently truncates at 512 KB; files slightly over the limit must be rejected at the preview layer, not crash. The "Salvar no iPhone" flow writes to `Documents/RemoteFiles/<container>/<subpath>` — a path traversal in the remote path would escape the sandbox.

## Preconditions
- Connected to an instance terminal (must be commander, not mirror)
- The active pane accepts shell input so QA can run `cd`, `pwd`, and `ls -1A` before opening the browser
- `~/Downloads/` exists on server and has at least 3 files: a `.md`, a `.pdf` (or binary), and one subfolder
- At least one subfolder inside `~/Downloads/` (e.g., `Documents/`)
- Optional for US-8: a video file ≥ 5 MB in `~/Downloads/` for progress indicator test

## Test Cases

### US-1 — Open browser

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-BROW-001 | Tap 📁 button in keybar (next to 📎) | FileBrowser sheet opens. Title = instance name. Breadcrumb shows current tmux pane path. File list appears | P1 | Yes |
| ST-Q-BROW-002 | Open browser when terminal has no active pane context (e.g., fresh connection before any output) | Browser opens, falls back to `~` as root path. No crash | P2 | Assisted |

### US-1A — Sync with terminal cwd

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-BROW-026 | In terminal, run `cd ~/Downloads/Documents/Reports && pwd && ls -1A`. Then tap 📁 | Breadcrumb path matches `pwd`. Browser list includes entries visible in `ls -1A` for that directory, such as `Exports/` and any marker file created during setup | P1 | Yes |
| ST-Q-BROW-027 | In terminal, create a non-default nested folder, e.g. `mkdir -p ~/Downloads/qa-cwd-sync/nested && printf 'from-terminal\n' > ~/Downloads/qa-cwd-sync/nested/from-terminal.txt && cd ~/Downloads/qa-cwd-sync/nested && pwd && ls -1A`. Then tap 📁 | Browser opens directly in the nested path from `pwd`, not in `~/Downloads`. File list includes the file(s) shown by `ls -1A` | P1 | Yes |
| ST-Q-BROW-028 | Open browser once from directory A, dismiss it, then in the same pane run `cd` to directory B, confirm with `pwd`/`ls -1A`, and tap 📁 again | Second open follows the latest pane cwd (directory B), not previous browser history or a fixed default path. Browser list matches the second `ls -1A` output | P1 | Yes |

### US-2 — Navigate hierarchically

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-BROW-003 | Tap a subfolder in the list | Directory content changes. Breadcrumb updates to show new path. Folder cells have disclosure indicator | P1 | Yes |
| ST-Q-BROW-004 | Tap a breadcrumb segment (e.g., "Downloads" when inside Documents/) | Browser navigates up to that path. List reloads. No animation artifact | P1 | Yes |
| ST-Q-BROW-005 | Navigate 3 levels deep, then tap root segment in breadcrumb | Jumps directly to root. Intermediate steps not required | P1 | Yes |
| ST-Q-BROW-006 | Verify favorite chips appear at top: Photos, Camera, Documents, Files, Location | All 5 chips visible and scrollable. Tapping one opens AttachmentSourceRouter flow (not file browser nav) | P2 | Yes |
| ST-Q-BROW-007 | Navigate into a subfolder created by the agent (not a favorite) — e.g., `Reports/` | Folder appears in normal list and is tappable. No special treatment required | P2 | Assisted |

### US-3 — Preview in-app

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-BROW-008 | Tap a `.md` file | Preview screen opens. Content rendered as formatted markdown (headers, bold, numbered lists, bullet lists, clickable links visible) | P1 | Assisted |
| ST-Q-BROW-009 | Tap a `.txt` or `.log` file | Preview opens as plain text. Monospaced font | P1 | Assisted |
| ST-Q-BROW-010 | Tap a `.swift`, `.json`, or `.sh` file | Preview opens. Content visible as plain text | P2 | Assisted |
| ST-Q-BROW-011 | Tap a `.pdf` file | Opens via Quick Look (QLPreviewController). PDF rendered in-app. No separate download required | P1 | Assisted |
| ST-Q-BROW-012 | Tap a video file (`.mp4`, `.mov`) | Opens via Quick Look. Playback controls visible. Video plays | P1 | Assisted |
| ST-Q-BROW-013 | Tap an image file (`.jpg`, `.png`) | Opens via Quick Look. Image rendered full-screen | P1 | Assisted |
| ST-Q-BROW-014 | Tap a truly unsupported extension (e.g., `.bin`, `.o`) | Error alert: "Preview not available for this file type." No crash | P2 | Yes |
| ST-Q-BROW-015 | Tap a previewable text file over 512 KB | Error alert: "Preview is limited to UTF-8 text files up to 512 KB." File size enforced client-side before fetch | P1 | Assisted |

### US-6 — Metadata

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-BROW-016 | View file list | Each file cell shows size (KB/MB) and modified date as subtitle. Folders show path as subtitle | P2 | Yes |

### US-7 — Pull to refresh

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-BROW-017 | Pull down on file list | Spinner appears. List reloads. Footer shows "Atualizado agora" after completion. New files added by agent during navigation appear | P2 | Yes |

### US-4 — Save to iPhone

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-BROW-018 | Open preview of a `.md` file. Tap "Salvar no iPhone" | File saved to `Documents/RemoteFiles/<container>/<path>/file.md`. Toast "Saved" appears | P1 | Assisted |
| ST-Q-BROW-019 | Open Files.app → On My iPhone → Soyeht | Previously saved file appears. Accessible offline | P1 | Manual |
| ST-Q-BROW-020 | Tap "Salvar em…" | `UIDocumentPickerViewController` opens. User can save to iCloud Drive or other provider | P2 | Assisted |

### US-5 — Share

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-BROW-021 | Open preview. Tap "Compartilhar" | `UIActivityViewController` opens with the file. AirDrop, Mail, etc. are options | P1 | Assisted |
| ST-Q-BROW-022 | Long-press a file in the list → "Share Path" | `UIActivityViewController` opens with the remote path string | P2 | Yes |

### US-8 — Download progress

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-BROW-023 | Tap a large video file (≥ 5 MB) | Cell expands (taller than standard 52pt). Shows horizontal progress bar + download speed (e.g., "1.2 MB/s"). Size label replaced. X (cancel) button visible on the right. No modal blocker | P1 | Assisted |
| ST-Q-BROW-024 | During active download, tap X cancel button on cell | Download cancels. Cell returns to normal state (size + date labels). No crash | P1 | Assisted |
| ST-Q-BROW-025 | Simulate download failure (disconnect network mid-download) | Error state appears in cell: red error banner + "Tentar de novo" button. Tapping retry restarts download. Progress bar returns | P1 | Assisted |

## Context Menu (Breadcrumb extra flows)

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| *(covered by existing ATCH domain for upload flows)* | | | | |

## Execution Notes
- For BROW-008 to BROW-010, create test files on the server before running: `echo "# Hello" > ~/Downloads/test.md`
- For BROW-026 to BROW-028, capture both `pwd` and `ls -1A` from the active pane immediately before tapping 📁. Compare breadcrumb path to `pwd`, and compare at least one browser row to an entry returned by `ls -1A`.
- For BROW-015 to BROW-016, the path in Files.app must match `Documents/RemoteFiles/<container>/Downloads/test.md`
- BROW-022 requires manually disabling Wi-Fi or using network conditioner during the download
- "Salvar no iPhone" and "Salvar em…" buttons only appear in `FilePreviewViewController`, not in the directory list
- BROW-011, BROW-012, BROW-013, BROW-018, BROW-020, BROW-021, BROW-023, BROW-024, and BROW-025 depend on `GET /api/v1/terminals/{container}/files/download` being available in the target backend environment

## Related Designs
- Root browser (aanGu), Subfolder nav (zf2wz), File preview (LxMjA), Download progress (8NmZu)
- Breadcrumb tap navigate up (pMVGn), Long press context menu (55LcN), History sheet (rhWgc), Git awareness (IbMCX)
