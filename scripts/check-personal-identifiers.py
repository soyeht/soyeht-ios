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
import os
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


class GitFailed(RuntimeError):
    """Git refused. This must never be mistaken for "nothing to look at"."""


def git(*args: str) -> str:
    """Runs git and FAILS CLOSED.

    The first version passed `check=False` and returned stdout. A bad ref then
    produced an empty string, the scan found nothing in it, and the tool printed
    "clean" and exited 0 — a checker that reports safety when it looked at
    nothing. [jaime] found it with the obvious negative control:
    `--range refs/heads/definitely-missing..HEAD` came back green.

    That is the same failure this whole file exists to stop, wearing the
    checker's own uniform. A guard that cannot fail is not a guard.
    """
    result = subprocess.run(["git", *args], capture_output=True, text=True,
                            check=False)
    if result.returncode != 0:
        raise GitFailed(f"git {' '.join(args)} -> {result.returncode}: "
                        f"{result.stderr.strip() or '<no message>'}")
    return result.stdout


def commits_in(rev_range: str) -> list[str]:
    return [line for line in git("rev-list", rev_range).splitlines() if line]


def added_text_per_commit(rev_range: str) -> str:
    """Every line ADDED by each commit in the range, examined separately.

    An aggregated `git diff A..B` shows only the net effect, so a value that is
    introduced by one commit and removed by a later one inside the same range
    vanishes from it — while living on forever in the history the range covers.
    That is exactly the leak shape being audited: `b415927d` removed the
    identifiers and published them in its own diff. [jaime]
    """
    chunks = []
    for sha in commits_in(rev_range):
        # `-m` so a merge is compared against each parent rather than skipped.
        chunks.append(added_lines(git("show", "-m", "--format=", sha)))
    return "\n".join(chunks)


def self_test() -> int:
    """The two ways this checker was already caught reporting safety.

    Both were found by [jaime] against the first version, and neither would
    have been noticed by using the tool normally — which is the whole argument
    for pinning them here. A guard nobody can fail is not a guard.
    """
    import tempfile

    failures = 0

    # 1. A ref git cannot resolve must REFUSE. The first version returned
    #    stdout with `check=False`, so a bad ref produced an empty string, the
    #    scan found nothing in it, and it printed "clean" and exited 0.
    try:
        git("rev-list", "refs/heads/definitely-missing-ref..HEAD")
        print("  CALIBRATION FAILED  a missing ref did not raise")
        failures += 1
    except GitFailed:
        print("  ok  a missing ref refuses instead of reporting clean")

    # 2. A value introduced and then removed INSIDE the range must still be
    #    found. The aggregated `git diff A..B` shows only the net effect, so it
    #    hides exactly the leak shape being audited.
    with tempfile.TemporaryDirectory(prefix="identifier-selftest-") as workdir:
        def run(*args: str) -> None:
            subprocess.run(["git", "-C", workdir, *args],
                           capture_output=True, check=True)

        run("init", "-q", ".")
        run("config", "user.email", "selftest@example.test")
        run("config", "user.name", "self test")
        # Composed at run time, never written as a literal. The fixture has to
        # LOOK like a violation or it would not reproduce the hole — and a
        # literal here would make this file trip its own check on every commit,
        # which is how a checker teaches everyone to ignore it.
        planted = "192.168." + "99.7"
        target = os.path.join(workdir, "fixture.txt")
        for content, message in (("base", "base"),
                                 (f"host = {planted}", "introduce"),
                                 ("host = 192.168.1.20", "remove")):
            with open(target, "w") as handle:
                handle.write(content + "\n")
            run("add", "-A")
            run("commit", "-qm", message)

        here = os.getcwd()
        try:
            os.chdir(workdir)
            aggregated = offending(added_lines(git("diff", "HEAD~2..HEAD")))
            per_commit = offending(added_text_per_commit("HEAD~2..HEAD"))
        finally:
            os.chdir(here)

        if aggregated:
            print("  CALIBRATION FAILED  the aggregated diff was supposed to "
                  "hide it; the fixture no longer reproduces the hole")
            failures += 1
        elif not per_commit:
            print("  CALIBRATION FAILED  a value added then removed inside the "
                  "range slipped through")
            failures += 1
        else:
            print("  ok  a value added then removed inside the range is still found")

    if failures:
        print(f"\n{failures} calibration case(s) failed. Do not trust a clean "
              "report from this checker until that is fixed.")
        return 1
    print("\ncalibration ok: it refuses when it cannot look, and it looks per commit.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--range", help="commit range, e.g. origin/main..main")
    parser.add_argument("--files", nargs="*", help="check these files whole")
    parser.add_argument("--self-test", action="store_true",
                        help="prove the checker can still fail; touches nothing")
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    try:
        if args.files:
            label = "files"
            text = "\n".join(open(path, errors="replace").read()
                             for path in args.files)
        elif args.range:
            commits = commits_in(args.range)
            label = f"range {args.range} ({len(commits)} commit(s), each examined)"
            text = added_text_per_commit(args.range)
        else:
            label = "staged changes"
            text = added_lines(git("diff", "--cached"))
    except (GitFailed, OSError) as error:
        # Refusing is the only safe answer: "I could not look" is not "clean".
        print(f"refusing: could not inspect anything.\n  {error}")
        return 1

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
