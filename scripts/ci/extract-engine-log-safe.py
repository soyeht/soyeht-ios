#!/usr/bin/env python3
"""Privacy-safe engine.log extractor — EXACT-token ALLOWLIST, not a redactor.

The engine.log captured on a CI runner can carry environment/identity — an
addr, a hostname, a tailnet IP, a MAC, a household pubkey, a Bonjour service
name, an error Display string. The run is public, so the raw log must never be
attached. This extractor reads the json-formatted engine.log (one JSON object
per line, produced with THEYOS_LOG_FORMAT=json) and emits ONLY `LEVEL stage`,
and ONLY when `stage` is an EXACT member of a small, closed, source-audited set.

Two allowlists, loaded as an EXACT UNION, kept as separate files for distinct
provenance:
 - engine-safe-stages.txt  : engine `stage` literals (pinned engine source).
 - harness-safe-stages.txt : TEST-HARNESS tokens the harness appends to the same
   engine.log as TWO synthetic events — a static case ID and a static
   BootstrapInitializeClient.initialize transport outcome class.

Why exact membership and not a prefix or charset guard: a stage is emitted three
ways — a compile-time literal, a format!(...) value, and a variable — and a
prefix admits a value-carrying token (an IP/hostname is `[a-z0-9_.]`), a charset
guard admits an interpolated all-lowercase token. Only exact-VALUE membership is
fail-closed across all three. No field value is interpreted, so there is no
value-injection surface.

Sentinel (no blind spot): the drop is not silent. If `fields` is a dict AND the
KEY `stage` is present but its value is NOT an exact string member — a string
non-member, or a dict / list / number / bool / null — the extractor prints the
fixed literal `engine_log_unlisted_stage_present` exactly ONCE. It carries zero
environmental information (a constant); it is a fixed disclosure that the view is
filtered. A MISSING `stage` key, a non-dict `fields`, or a non-JSON / non-dict
top level stays fully silent (there is no stage decision to make).

Robustness: stdin is read as bytes and decoded UTF-8 with errors='replace', so a
non-UTF-8 byte cannot crash the extractor; the replacement (U+FFFD) cannot forge
an ASCII allowlist member.
"""
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_STAGE_FILES = (
    os.path.join(_HERE, "engine-safe-stages.txt"),
    os.path.join(_HERE, "harness-safe-stages.txt"),
)

# Levels are a fixed enum; anything else prints as "?" rather than echoing text.
SAFE_LEVELS = {"TRACE", "DEBUG", "INFO", "WARN", "WARNING", "ERROR"}

# Fixed sentinel — a constant, encodes only "an unlisted stage was present".
UNLISTED_SENTINEL = "engine_log_unlisted_stage_present"


def load_safe_stages(paths) -> frozenset:
    stages = set()
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                token = line.strip()
                if token and not token.startswith("#"):
                    stages.add(token)
    return frozenset(stages)


def safe_level(event: dict) -> str:
    raw_level = event.get("level")
    level = raw_level.upper() if isinstance(raw_level, str) else "?"
    return level if level in SAFE_LEVELS else "?"


def main() -> int:
    safe_stages = load_safe_stages(_STAGE_FILES)
    # Read bytes, decode leniently: an invalid UTF-8 byte must not crash us.
    text = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    unlisted_seen = False
    for raw in text.splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            event = json.loads(raw)
        except (ValueError, TypeError):
            continue  # non-JSON: silent
        if not isinstance(event, dict):
            continue  # non-dict top level: silent
        fields = event.get("fields")
        if not isinstance(fields, dict):
            continue  # non-dict fields: silent
        if "stage" not in fields:
            continue  # missing stage key: silent (no decision to make)
        stage = fields["stage"]
        if isinstance(stage, str) and stage in safe_stages:
            print(f"{safe_level(event)} {stage}")
        else:
            # Key present, value not an exact string member — string non-member OR
            # dict/list/number/bool/null. Record omission; never print the value.
            unlisted_seen = True
    if unlisted_seen:
        print(UNLISTED_SENTINEL)
    return 0


if __name__ == "__main__":
    sys.exit(main())
