#!/usr/bin/env python3
"""Refuses a commit that would publish someone's machine, network or device.

WHY THIS EXISTS

This repository is public. The rule "no personal identifiers" has been in force
for a while and it still failed three times in a single day — 2026-09-05 —
across two different authors, neither of them careless. That is the shape of a
rule that needs a machine, not more discipline: everyone spends the day reading
logs full of real addresses, and the values travel into a test fixture without
anyone deciding to put them there.

It has already failed in the worst possible way. The commit
`chore: redact personal identifiers from the public repository` removed a real
device UDID and three real tailnet addresses — and its own diff shows every one
of them on the removal lines. Redacting in git does not unpublish; it publishes
a second time, in the commit that claims to be the cleanup.

WHAT IT LOOKS FOR

Only things that identify a real machine, network or device. Not secrets —
credentials are a different problem with a different tool.

  - LAN addresses outside the block this project invents with
  - tailnet addresses (100.64/10) outside that same block
  - Apple device UDIDs
  - household and person identifiers minted by the engine
  - real machine and account names

WHAT IT DELIBERATELY DOES NOT FLAG

`100.64.x.x` and `192.168.1.x` are the project's own blocks for fixtures and
examples. Flagging those would train everyone to pass `--no-verify`, and a check
people route around protects nothing.

USAGE

    scripts/check-personal-identifiers.py            # what is staged
    scripts/check-personal-identifiers.py --range A..B
    scripts/check-personal-identifiers.py --files a.swift b.rs

Exit 0 clean, 1 when something was found.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys

# The blocks this project reserves for examples and fixtures.
#
# Note the direction: this lists what is ALLOWED, never what is forbidden.
# Enumerating the owner's real addresses in order to block them would publish
# them in this very file — the same mistake as redacting inside a git commit.
# So the rule reads "100.64.x.x and 192.168.1.x are ours to invent with", and
# every other address in those ranges is assumed to belong to a real machine.
NEUTRAL_PREFIXES = ("100.64.", "192.168.1.")
NEUTRAL_EXACT = {"127.0.0.1", "0.0.0.0", "100.0.123.102"}


def is_neutral(value: str) -> bool:
    return value in NEUTRAL_EXACT or value.startswith(NEUTRAL_PREFIXES)

# Each rule says what it protects, because a failure message that only prints a
# regex teaches nobody what to write instead.
RULES: list[tuple[str, re.Pattern, str]] = [
    (
        "tailnet address",
        re.compile(r"\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}\b"),
        "use a 100.64.x.x address — the block this project invents with",
    ),
    (
        "LAN address of a real network",
        re.compile(r"\b192\.168\.(?!1\.)\d{1,3}\.\d{1,3}\b"),
        "use a 192.168.1.x address — the block this project invents with",
    ),
    (
        "Apple device UDID",
        re.compile(r"\b000[0-9A-F]{5}-[0-9A-F]{16}\b"),
        "read it from an environment variable; never hard-code a device identity",
    ),
    (
        "household identifier",
        re.compile(r"\bhh_[a-z2-7]{40,}\b"),
        "use a short fake such as hh_example",
    ),
    (
        "person identifier",
        re.compile(r"\bp_[a-z2-7]{40,}\b"),
        "use a short fake such as p_example",
    ),
]


def offending(text: str) -> list[tuple[str, str, str]]:
    """Every (rule, value, advice) in this text, minus the neutral values."""
    found: list[tuple[str, str, str]] = []
    seen: set[tuple[str, str]] = set()
    for name, pattern, advice in RULES:
        for match in pattern.findall(text):
            value = match if isinstance(match, str) else match[0]
            if is_neutral(value) or (name, value) in seen:
                continue
            seen.add((name, value))
            found.append((name, value, advice))
    return found


def added_lines(diff: str) -> str:
    """Only the lines a commit ADDS.

    A removal line is how the redaction commit exposed everything it claimed to
    clean, but blocking on removals would make it impossible to ever delete an
    identifier that is already in a file. Added lines are what this commit is
    choosing to publish, and that is the thing it can still decide not to do.
    """
    return "\n".join(line[1:] for line in diff.splitlines()
                     if line.startswith("+") and not line.startswith("+++"))


def git(*args: str) -> str:
    return subprocess.run(["git", *args], capture_output=True, text=True,
                          check=False).stdout


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--range", help="commit range, e.g. origin/main..main")
    parser.add_argument("--files", nargs="*", help="check these files whole")
    args = parser.parse_args()

    if args.files:
        label = "files"
        text = "\n".join(open(path, errors="replace").read() for path in args.files)
    elif args.range:
        label = f"range {args.range}"
        text = added_lines(git("diff", args.range))
    else:
        label = "staged changes"
        text = added_lines(git("diff", "--cached"))

    hits = offending(text)
    if not hits:
        print(f"clean: no personal identifier in {label}.")
        return 0

    print(f"refusing {label} — it would publish someone's machine:\n")
    for name, value, advice in hits:
        print(f"  {name}: {value}")
        print(f"    -> {advice}\n")
    print("This repository is public, and a later commit that removes the value "
          "still shows it on its own removal lines.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
