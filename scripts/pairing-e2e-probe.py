#!/usr/bin/env python3
"""Measures one end-to-end pairing run and says WHICH invariant broke.

WHY THIS EXISTS

On 2026-09-05 the owner sat watching a spinner. Both test suites were green,
the Mac was listening on the tailnet address AND the LAN address, the firewall
was off, and the phone had a direct tailnet route. None of that answered the
question that mattered — *which address did the phone dial, and what came
back* — because the answer lives in three logs, on two machines, and nothing
joins them.

This joins them. It is not a unit test wearing a different hat: it reads what
all THREE participants recorded during ONE real run and checks the invariants
against that.

WHAT IT MEASURES, AND FROM WHERE

  Mac     os_log, subsystem `com.soyeht.mac`   ->  the address OFFERED in the claim
  iPhone  os_log, subsystem `com.soyeht.mobile`, via `log collect` because
          `idevicesyslog` does not carry our subsystem (measured 2026-09-05)
                                               ->  the address CHOSEN and TRIED
  engine  `~/Library/Logs/SoyehtDev/engine.log`
                                               ->  what ARRIVED, and the outcome

Correlating the three is the whole point. Each one alone lies by omission: the
Mac says it notified the phone, the engine says nothing arrived, and without
the phone in the middle there is no way to tell whether it dialled the wrong
address or never dialled at all.

THE INVARIANTS

  TAILNET-KEPT      a phone with a tailnet address chooses tailnet AND persists
                    tailnet. This is the property that protects someone who
                    leaves the house.
  LAN-WORKS         a phone with no tailnet pairs over the LAN. Explicit owner
                    decision, proven on the device 2026-09-05; a regression here
                    is a failure, not "safer behaviour".
  NO-SILENT-LAN     a phone WITH tailnet never persists a LAN address.
  PROFILE-ISOLATED  production and Dev never claim each other's phone.
  NO-SPINNER        every run ends in success, typed failure or cancellation.
                    An unbounded wait is a failure.
  FIRST-PHONE       a household whose only member is the Mac admits the first
                    iPhone without approval from a third party that cannot exist.
  CAPABILITY-HONEST a locked owner key is never reported as a missing one.
  WORDS-MATCH       the six words the Mac shows are the six the phone shows.
                    Two screens showing six words each prove nothing until they
                    are the SAME six.

CALIBRATION

Green only means something if red is reachable. `--self-test` runs the
invariants against synthetic transcripts of good and bad runs and requires both
sides to land. If the self-test does not pass, this probe judges nothing.

SAFETY

Only looks at the Dev pair (bootstrap 8101, admin 8902). Refuses to run against
production (8091/8892) and never writes anything production owns.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field, asdict

DEV_BOOTSTRAP_PORT = 8101
DEV_ADMIN_PORT = 8902
PROD_BOOTSTRAP_PORT = 8091
PROD_ADMIN_PORT = 8892

DEV_ENGINE_LOG = os.path.expanduser("~/Library/Logs/SoyehtDev/engine.log")
DEV_APP_PROCESS = "Soyeht Dev"
MAC_SUBSYSTEM = "com.soyeht.mac"
PHONE_SUBSYSTEM = "com.soyeht.mobile"

TAILNET_RE = re.compile(r"\b100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}\b")
LOOPBACK_RE = re.compile(r"\b(127\.\d{1,3}\.\d{1,3}\.\d{1,3}|::1|localhost)\b")
IPV4_RE = re.compile(r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b")


def classify(host: str | None) -> str:
    """tailnet / lan / loopback / unknown — the same partition the engine uses.

    Accepts a bare host or a full URL; callers should not have to care which.
    """
    if not host:
        return "unknown"
    if LOOPBACK_RE.search(host):
        return "loopback"
    if TAILNET_RE.search(host):
        return "tailnet"
    if IPV4_RE.search(host):
        return "lan"
    return "unknown"


# ───────────────────────── what each side recorded ─────────────────────────


@dataclass
class Transcript:
    """One run's three tapes, as text, each line kept with its origin."""

    mac: list[str] = field(default_factory=list)
    phone: list[str] = field(default_factory=list)
    engine: list[str] = field(default_factory=list)

    def mac_grep(self, needle: str) -> list[str]:
        return [line for line in self.mac if needle in line]

    def phone_grep(self, needle: str) -> list[str]:
        return [line for line in self.phone if needle in line]

    def engine_grep(self, needle: str) -> list[str]:
        return [line for line in self.engine if needle in line]


def first_host(lines: list[str], key: str) -> str | None:
    """The value of `key=` (a host or a URL) on the first line that carries it.

    Handles `host=1.2.3.4`, `mac=http://1.2.3.4:8101` and `endpoint=…`, which
    are the three shapes our logs actually emit today.
    """
    for line in lines:
        match = re.search(rf"{re.escape(key)}=(\S+)", line)
        if match:
            return match.group(1)
    return None


# ───────────────────────────── the invariants ─────────────────────────────
#
# Each one answers a question and returns a verdict plus its evidence. The
# verdict is "pass", "fail" or "n/a" — n/a when the scenario does not exercise
# it. n/a NEVER counts as a pass: the summary keeps them apart on purpose,
# because counting them together is how a suite stays green while the product
# is broken.


@dataclass
class Finding:
    name: str
    verdict: str  # pass | fail | n/a
    detail: str


def engine_accepted(t: Transcript) -> bool:
    """The ENGINE accepted. Says nothing about the phone.

    `device_pairing.request.success` and `device_pairing.approve.success` mean
    a pending request was stored and a verified certificate was accepted by the
    store. Neither proves the phone fetched it, validated it, or saved a
    session. Treating engine acceptance as a completed pairing is the same
    mistake as reading engine silence as failure — one direction of it burned
    this probe already. [jaime]
    """
    return bool(t.engine_grep("device_pairing.approve.success")
                or t.engine_grep("pair_device.confirm.success"))


def phone_concluded(t: Transcript) -> bool:
    """The PHONE finished: it has a session it can use."""
    return bool(t.phone_grep("pair.result=paired")
                or t.phone_grep("endpoint.persisted"))


def paired_outcome(t: Transcript) -> bool:
    """A pairing that both ends agree happened."""
    return engine_accepted(t) and phone_concluded(t)


def inv_tailnet_kept(t: Transcript, phone_has_tailnet: bool) -> Finding:
    if not phone_has_tailnet:
        return Finding("TAILNET-KEPT", "n/a", "phone has no tailnet in this scenario")
    chosen = first_host(t.phone_grep("pair.endpoint"), "host")
    if chosen is None:
        return Finding("TAILNET-KEPT", "fail", "the phone recorded no chosen address")
    kind = classify(chosen)
    if kind == "tailnet":
        return Finding("TAILNET-KEPT", "pass", f"chose tailnet ({chosen})")
    return Finding("TAILNET-KEPT", "fail",
                   f"phone has a tailnet address and chose {kind} ({chosen}); "
                   "it loses the Mac the moment it leaves the house")


def inv_lan_works(t: Transcript, phone_has_tailnet: bool) -> Finding:
    if phone_has_tailnet:
        return Finding("LAN-WORKS", "n/a", "this scenario does not exercise pure LAN")
    # Either ceremony's evidence of an address actually dialled. The QR path
    # posts a confirm; the device-pairing path resolves an engine and talks to
    # it. Looking only for the confirm made this report "never reached the
    # confirm step" about a run that had no confirm step to reach. [jaime]
    tried = (first_host(t.phone_grep("pair.confirm.post"), "host")
             or first_host(t.phone_grep("resolveDiscoveredMac.entry"), "engines")
             or first_host(t.phone_grep("mac_browser.endpoint"), "endpoint"))
    if tried is None:
        return Finding("LAN-WORKS", "fail",
                       "the phone never dialled any address")
    if classify(tried) != "lan":
        return Finding("LAN-WORKS", "fail",
                       f"no tailnet available, yet it tried {classify(tried)} ({tried})")
    if paired_outcome(t):
        return Finding("LAN-WORKS", "pass",
                       f"paired over the LAN ({tried}): the engine accepted "
                       "and the phone saved a session")
    if engine_accepted(t) and not phone_concluded(t):
        return Finding("LAN-WORKS", "fail",
                       f"the engine accepted over the LAN ({tried}) and the "
                       "phone never ended up with a session — the two ends "
                       "disagree about whether this worked")
    if t.phone_grep("pair.failed") or t.phone_grep("pair.result=failed"):
        return Finding("LAN-WORKS", "fail",
                       f"tried the LAN ({tried}) and the pairing failed")
    # There are TWO pairing ceremonies and only one of them records success.
    # `handlers_pair_device.rs:460` logs `pair_device.confirm.success`;
    # `handlers_device_pairing.rs` (request/approve, the second-device path)
    # carries only `tracing::warn!` and is silent when it works. Reading that
    # silence as failure made this invariant impossible to satisfy on the
    # second-device path — a check that can never pass, which is worse than no
    # check. [jaime]
    return Finding("LAN-WORKS", "n/a",
                   f"tried the LAN ({tried}) and no side recorded an outcome; "
                   "the device-pairing path logs nothing on success, so this "
                   "cannot be judged from the tapes yet")


def inv_no_silent_lan(t: Transcript, phone_has_tailnet: bool) -> Finding:
    if not phone_has_tailnet:
        return Finding("NO-SILENT-LAN", "n/a", "only applies to a tailnet-capable phone")
    saved = first_host(t.phone_grep("endpoint.persisted"), "host")
    if saved is None:
        return Finding("NO-SILENT-LAN", "n/a", "nothing was persisted in this run")
    if classify(saved) == "lan":
        return Finding("NO-SILENT-LAN", "fail",
                       f"stored a LAN address ({saved}) on a tailnet-capable phone")
    return Finding("NO-SILENT-LAN", "pass", f"stored {classify(saved)} ({saved})")


def inv_profile_isolated(t: Transcript) -> Finding:
    """Neither install profile claims the other's phone.

    Measured 2026-09-05: Dev and production claimed the same handset 50 seconds
    apart, Dev won, and it told the phone to dial the wrong engine.
    """
    claims = t.mac_grep("direct_probe.claim")
    if not claims:
        # Passing here because no claim crossed the line, when no claim was
        # made at all, is a green earned by nothing happening. The rehearsal of
        # 2026-09-05 produced exactly that: the driver failed before touching
        # anything and this still reported "ok".
        return Finding("PROFILE-ISOLATED", "n/a",
                       "no claim was attempted in this run")
    strangers = [line for line in claims if f":{PROD_BOOTSTRAP_PORT}" in line]
    if strangers:
        return Finding("PROFILE-ISOLATED", "fail",
                       f"Dev claimed a production target: {strangers[0][:120]}")
    return Finding("PROFILE-ISOLATED", "pass",
                   f"{len(claims)} claim(s), none crossed the profile line")


# A pending approval is allowed to wait this long by design, so a capture
# shorter than it cannot distinguish "waiting" from "waiting forever".
APPROVAL_DEADLINE_SECS = 300


def inv_no_spinner(t: Transcript, captured_secs: float | None = None) -> Finding:
    """Every run ends. An unbounded wait is the defect, not the symptom.

    But a run legitimately waiting for an owner has up to
    APPROVAL_DEADLINE_SECS to be approved. Calling that a spinner because the
    capture ended first would report a defect that the product does not have,
    and the tape cannot tell the two apart. [jaime]
    """
    ended = (t.phone_grep("pair.result=") or t.phone_grep("pair.failed")
             or t.engine_grep("pair_device.confirm.success"))
    if ended:
        return Finding("NO-SPINNER", "pass", "the run reached an outcome")
    awaiting = t.phone_grep("pairing_review_digest") or t.phone_grep("awaiting")
    if awaiting and (captured_secs is None or captured_secs < APPROVAL_DEADLINE_SECS):
        return Finding("NO-SPINNER", "n/a",
                       f"still inside the {APPROVAL_DEADLINE_SECS}s approval "
                       f"window when the capture ended"
                       + (f" ({captured_secs:.0f}s)" if captured_secs else "")
                       + "; a shorter capture cannot prove an endless wait")
    return Finding("NO-SPINNER", "fail",
                   "no outcome recorded: the person was left on the spinner")


def inv_first_phone(t: Transcript, household_devices: int | None) -> Finding:
    """A household holding only the Mac must admit the first iPhone.

    `ForgetHomeService.swift:11-16` has documented the dead end since
    2026-09-01: with no iPhone already in the household, the new one waits for
    an approval that can never arrive — "five minutes of spinner and then a
    timeout".
    """
    # `device_count` is `u32::from(owner_auth.is_some())` — a boolean about
    # owner authority (`handlers_bootstrap.rs:3369`), never a roster. So this
    # invariant applies ONLY when it is 0: no owner established. A 1 means an
    # owner exists, and a Mac without a local owner session is then a member
    # without local authority, not a household nobody owns. Treating 1 as "the
    # first phone should walk in" would turn this run into an argument for
    # reopening first-owner, which is the one thing it must never do. [jaime]
    if household_devices != 0:
        return Finding("FIRST-PHONE", "n/a",
                       f"an owner is already established (device_count="
                       f"{household_devices}); this is not the ownerless case")
    blocked = (t.mac_grep("already belongs to this home")
               or t.phone_grep("awaiting_approval"))
    if blocked:
        return Finding("FIRST-PHONE", "fail",
                       "a Mac-only household asked approval of an iPhone that "
                       "does not exist")
    if not t.engine_grep("pair_device.confirm.success"):
        return Finding("FIRST-PHONE", "fail", "the first iPhone never joined")
    return Finding("FIRST-PHONE", "pass", "the first iPhone joined with no third party")


# The six owner-signing capability states, from [jaime]'s addendum G. The
# distinction that matters: a key that EXISTS but needs unlocking is not "I
# have no key". Conflating them is what would tell an owner they lost their
# household when a Touch ID prompt would have settled it — the same family as
# the `errSecInternalComponent` that bit us in panes with no GUI session.
OWNER_CAPABILITY_STATES = {
    "no_session",            # this Mac holds no household session at all
    "identity_mismatch",     # holds a session, but for a different household
    "no_key",                # right session, owner key genuinely absent
    "needs_authentication",  # key present; signing requires an owner gesture
    "proven",                # signature produced and verified against the cert
    "error",                 # failed for another reason, carried with it
}

# Causes that mean "the read did not succeed", never "the thing is not there".
# Grown from the OSStatus family into decode and access denial as well: the
# capability now covers session lookup too, and a session that failed to decode
# is not a session that does not exist.
_ACCESS_FAILED = re.compile(
    r"interaction[_ -]?not[_ -]?allowed|errSecInteractionNotAllowed|-25308"
    r"|user interaction is not allowed|errSecAuthFailed|LAError"
    r"|errSec[A-Za-z]*(?:Denied|Failed|Invalid)|decod(?:e|ing)[_ -]?fail"
    r"|access[_ -]?denied|read[_ -]?failed|keychain[_ -]?error",
    re.IGNORECASE,
)


def inv_capability_honest(t: Transcript) -> Finding:
    """The Mac states what it can do, and never calls "locked" "missing".

    Without this, G returns to the same dead end by another road: the screen
    would say "I need the iPhone that holds the key" to an owner whose key is
    right there, behind an unlock nobody asked for.
    """
    lines = t.mac_grep("owner_capability=")
    if not lines:
        return Finding("CAPABILITY-HONEST", "n/a",
                       "the Mac declared no capability in this run")
    match = re.search(r"owner_capability=(\w+)", lines[0])
    state = match.group(1) if match else "<unreadable>"
    if state not in OWNER_CAPABILITY_STATES:
        return Finding("CAPABILITY-HONEST", "fail", f"state outside the contract: {state}")
    # Two ways of claiming absence when the truth is "I could not look".
    # `no_key` covering a denied unlock was the first; `no_session` covering a
    # keychain read that failed is the same lie one level up, and it reads as
    # "this Mac has no home" — which is how an owner gets told to start over.
    if state in ("no_key", "no_session"):
        lying = [l for l in lines if _ACCESS_FAILED.search(l)]
        if lying:
            return Finding("CAPABILITY-HONEST", "fail",
                           f"reported {state} when the cause was a failed or denied "
                           f"read: {lying[0][:110]}. Absence and 'I could not look' "
                           "are different answers, and this one sends the owner to "
                           "erase a household they still control")
    return Finding("CAPABILITY-HONEST", "pass", f"declared {state}")


# ONLY `pairing_review_digest`. The engine also logs a `request_digest` — a
# BLAKE3 of the request id that correlates its own two lines and says nothing
# about the words on either screen. Matching it here would let two engine log
# lines "prove" that a person compared six words nobody showed them. [jaime]
DIGEST_RE = re.compile(r"\bpairing_review_digest=([0-9a-f]{64})\b")


def digests_in(lines: list[str]) -> set[str]:
    return {m.group(1) for line in lines for m in [DIGEST_RE.search(line)] if m}


def inv_words_match(t: Transcript) -> Finding:
    """The six words on the Mac must be the six words on the phone.

    The approval ceremony asks a person to compare two screens. Six words on
    each proves nothing until they are the SAME six — and a machine reading
    both ends is the only way to say that without someone squinting at two
    displays.

    Both sides log `pairing_review_digest=` from one shared derivation
    (`DevicePairingReview.diagnostic`), so this compares tape to tape. The
    driver reads the phone's words too, but its reading never reaches this
    verdict: whoever acts must not feed whoever judges.

    SETS, not first-match. There are several emitters per side now — the Mac
    logs on arrival and on approval, and the phone logs from the proximity,
    deep-link and approver paths. Taking the first digest from each tape would
    pair unrelated requests whenever a run carries two, and report a mismatch
    that never happened, or agreement that never happened.
    """
    mac_seen = digests_in(t.mac_grep("pairing_review_digest"))
    phone_seen = digests_in(t.phone_grep("pairing_review_digest"))

    # If this Mac cannot approve, it is not the approver, and its silence is
    # authorization working rather than a broken ceremony. Blaming it for
    # showing no words would turn a member Mac into a defect. [jaime]
    capability = re.search(r"owner_capability=(\w+)",
                           "\n".join(t.mac_grep("owner_capability=")))
    if (capability and capability.group(1) not in ("proven", "needs_authentication")
            and not mac_seen):
        return Finding("WORDS-MATCH", "n/a",
                       f"this Mac is not the approver (owner_capability="
                       f"{capability.group(1)}); the words belong on whichever "
                       "device holds the owner key")

    if not mac_seen and not phone_seen:
        # "Never got there" and "got there and disagreed" are different
        # answers. A malformed digest is a third, and must not read as absent.
        malformed = [line for line in t.mac + t.phone
                     if "pairing_review_digest" in line]
        if malformed:
            return Finding("WORDS-MATCH", "fail",
                           f"digest present but not 64 lowercase hex: {malformed[0][:100]}")
        return Finding("WORDS-MATCH", "n/a", "this run never reached owner approval")

    if not mac_seen:
        return Finding("WORDS-MATCH", "fail",
                       "only the phone derived the words; the approver has "
                       "nothing to compare against")
    if not phone_seen:
        return Finding("WORDS-MATCH", "fail",
                       "only the Mac derived the words; the person is asked to "
                       "compare against a screen that shows none")

    mac_only = mac_seen - phone_seen
    phone_only = phone_seen - mac_seen
    if mac_only or phone_only:
        return Finding("WORDS-MATCH", "fail",
                       f"a request was reviewed on one end only "
                       f"(Mac-only {sorted(d[:12] for d in mac_only)}, "
                       f"phone-only {sorted(d[:12] for d in phone_only)}); "
                       "approving here could confirm the wrong request")
    return Finding("WORDS-MATCH", "pass",
                   f"both ends derived the same words for all "
                   f"{len(mac_seen)} request(s)")


def judge(t: Transcript, phone_has_tailnet: bool,
          household_devices: int | None,
          captured_secs: float | None = None) -> list[Finding]:
    return [
        inv_tailnet_kept(t, phone_has_tailnet),
        inv_lan_works(t, phone_has_tailnet),
        inv_no_silent_lan(t, phone_has_tailnet),
        inv_profile_isolated(t),
        inv_no_spinner(t, captured_secs),
        inv_first_phone(t, household_devices),
        inv_capability_honest(t),
        inv_words_match(t),
    ]


# ───────────────────────── collecting the three tapes ─────────────────────


def guard_not_production(bootstrap_port: int) -> None:
    if bootstrap_port in (PROD_BOOTSTRAP_PORT, PROD_ADMIN_PORT):
        sys.exit(f"refused: this probe never talks to production "
                 f"({PROD_BOOTSTRAP_PORT}/{PROD_ADMIN_PORT}). "
                 f"The Dev pair is {DEV_BOOTSTRAP_PORT}/{DEV_ADMIN_PORT}.")


def engine_offset(path: str) -> int:
    return os.path.getsize(path) if os.path.exists(path) else 0


def engine_tail(path: str, since_offset: int) -> list[str]:
    """Whatever the engine appended after `since_offset`."""
    if not os.path.exists(path):
        return []
    with open(path, "r", errors="replace") as handle:
        handle.seek(since_offset)
        return handle.read().splitlines()


def start_mac_capture(out_path: str, process: str) -> subprocess.Popen:
    """Streams the Mac app's os_log. `--level info` because the pairing
    categories log at `.info` and those do not persist in the default store."""
    handle = open(out_path, "w")
    return subprocess.Popen(
        ["/usr/bin/log", "stream", "--level", "info", "--style", "compact",
         "--predicate", f'subsystem == "{MAC_SUBSYSTEM}" AND process == "{process}"'],
        stdout=handle, stderr=subprocess.STDOUT,
    )


def collect_phone_log(udid: str, minutes: int, out_dir: str) -> list[str]:
    """`log collect` is the only way in: `idevicesyslog` does not carry our
    subsystem (measured 2026-09-05). Needs passwordless sudo and the cable."""
    archive = os.path.join(out_dir, "iphone.logarchive")
    shutil.rmtree(archive, ignore_errors=True)
    collected = subprocess.run(
        ["sudo", "-n", "/usr/bin/log", "collect", "--device-udid", udid,
         "--last", f"{minutes}m", "--output", archive],
        capture_output=True, text=True,
    )
    if collected.returncode != 0:
        return [f"<<no phone log: {collected.stderr.strip()}>>"]
    shown = subprocess.run(
        ["/usr/bin/log", "show", "--archive", archive, "--style", "compact",
         "--info", "--predicate", f'subsystem == "{PHONE_SUBSYSTEM}"'],
        capture_output=True, text=True,
    )
    return shown.stdout.splitlines()


def household_device_count(port: int) -> int | None:
    """NOTE: the engine's `device_count` is `u32::from(owner_auth.is_some())`
    (`handlers_bootstrap.rs:3369`) — a boolean about owner authority, never a
    device roster. Used here only to tell "no owner yet" from "owner exists"."""
    import urllib.request
    try:
        with urllib.request.urlopen(
                f"http://127.0.0.1:{port}/bootstrap/status", timeout=4) as response:
            return json.load(response).get("device_count")
    except Exception:
        return None


# ─────────────────────────────── calibration ───────────────────────────────
#
# Synthetic transcripts. They do not replace a real run — they prove the
# judgement can tell the two apart. A probe that never fails measures nothing.

GOOD_TAILNET = Transcript(
    mac=["direct_probe.notified iphone=http://192.168.1.50:8092/ "
         "mac=http://100.64.0.10:8101"],
    phone=["pair.endpoint source=reached host=100.64.0.10 port=8101",
           "pair.confirm.post host=100.64.0.10 port=8101",
           "endpoint.persisted host=100.64.0.10",
           "pair.result=paired"],
    engine=["pair_device.confirm.success elapsed_ms=180"],
)

GOOD_LAN = Transcript(
    mac=["direct_probe.notified iphone=http://192.168.1.50:8092/ "
         "mac=http://192.168.1.20:8101"],
    phone=["pair.endpoint source=claim host=192.168.1.20 port=8101",
           "pair.confirm.post host=192.168.1.20 port=8101",
           "endpoint.persisted host=192.168.1.20",
           "pair.result=paired"],
    engine=["pair_device.confirm.success elapsed_ms=210"],
)

BAD_SILENT_LAN = Transcript(
    mac=["direct_probe.notified mac=http://100.64.0.10:8101"],
    phone=["pair.endpoint source=reached host=192.168.1.20 port=8101",
           "pair.confirm.post host=192.168.1.20 port=8101",
           "endpoint.persisted host=192.168.1.20",
           "pair.result=paired"],
    engine=["pair_device.confirm.success"],
)

BAD_SPINNER = Transcript(
    mac=["direct_probe.notified mac=http://100.64.0.10:8101"],
    phone=["pair.endpoint source=claim host=100.64.0.10 port=8101"],
    engine=[],
)

BAD_FIRST_PHONE = Transcript(
    mac=["Finish approval on an iPhone that already belongs to this home"],
    phone=["pair.endpoint source=claim host=100.64.0.10 port=8101",
           "awaiting_approval"],
    engine=[],
)

BAD_CROSS_PROFILE = Transcript(
    mac=[f"direct_probe.claim_already_initialized "
         f"iphone=http://192.168.1.50:{PROD_BOOTSTRAP_PORT}/"],
    phone=["pair.result=paired"],
    engine=["pair_device.confirm.success"],
)

GOOD_CAPABILITY_LOCKED = Transcript(
    mac=["owner_capability=needs_authentication reason=user-presence-required",
         "approval.offer shown=Approve on this Mac — unlock required"],
    phone=["pair.result=awaiting_owner_approval"],
    engine=[],
)

BAD_CAPABILITY_LIES = Transcript(
    mac=["owner_capability=no_key cause=errSecInteractionNotAllowed",
         "approval.offer shown=I need the iPhone that holds the key"],
    phone=["pair.result=failed"],
    engine=[],
)


SAME = "a" * 64
OTHER = "b" * 64

GOOD_WORDS_MATCH = Transcript(
    mac=[f"pairing_review_digest={SAME}"],
    phone=[f"pairing_review_digest={SAME}", "pair.result=paired"],
    engine=["pair_device.confirm.success"],
)

BAD_WORDS_DIFFER = Transcript(
    mac=[f"pairing_review_digest={SAME}"],
    phone=[f"pairing_review_digest={OTHER}", "pair.result=paired"],
    engine=["pair_device.confirm.success"],
)

BAD_WORDS_ONE_SIDED = Transcript(
    mac=[f"pairing_review_digest={SAME}"],
    phone=["pair.result=awaiting_owner_approval"],
    engine=[],
)


# Two requests in one run, logged in OPPOSITE order on each side. Comparing
# the first digest of each tape pairs A against B and reports a mismatch that
# never happened. This case exists to keep that bug from coming back.
GOOD_TWO_REQUESTS_ANY_ORDER = Transcript(
    mac=[f"pairing_review_digest={SAME}", f"pairing_review_digest={OTHER}"],
    phone=[f"pairing_review_digest={OTHER}", f"pairing_review_digest={SAME}",
           "pair.result=paired"],
    engine=["pair_device.confirm.success"],
)

# The Mac reviewed two requests, the phone only showed one. Somebody is being
# asked to approve a request whose words they were never shown.
BAD_ONE_REQUEST_UNREVIEWED = Transcript(
    mac=[f"pairing_review_digest={SAME}", f"pairing_review_digest={OTHER}"],
    phone=[f"pairing_review_digest={SAME}", "pair.result=paired"],
    engine=["pair_device.confirm.success"],
)


# A run that really did claim, on the Dev bootstrap port. Without this the
# suite would only ever exercise n/a and fail for PROFILE-ISOLATED, and the
# pass path would be untested — the same vacuity, one level up.
GOOD_CLAIM_IN_PROFILE = Transcript(
    mac=[f"direct_probe.claim_already_initialized "
         f"iphone=http://192.168.1.50:{DEV_BOOTSTRAP_PORT}/",
         f"pairing_review_digest={SAME}"],
    phone=[f"pairing_review_digest={SAME}", "pair.result=paired"],
    engine=["pair_device.confirm.success"],
)


BAD_SESSION_LIES = Transcript(
    mac=["owner_capability=no_session cause=errSecInteractionNotAllowed",
         "approval.offer shown=this Mac has no home"],
    phone=["pair.result=failed"],
    engine=[],
)

GOOD_SESSION_TRULY_ABSENT = Transcript(
    mac=["owner_capability=no_session cause=item_not_found"],
    phone=["pair.result=failed"],
    engine=[],
)


# The engine accepted, and the phone never got a session. Both ends have to
# agree, or "it worked" is only true on one machine.
BAD_ENGINE_ONLY = Transcript(
    mac=[],
    phone=["pair.confirm.post host=192.168.1.20 port=8101"],
    engine=["device_pairing.approve.success request_digest=" + "c" * 64],
)

# The engine's own correlation digest must not be mistaken for the words.
BAD_REQUEST_DIGEST_IS_NOT_WORDS = Transcript(
    mac=["owner_capability=proven"],
    phone=["pairing_review_digest=" + SAME],
    engine=["device_pairing.request.success request_digest=" + SAME,
            "device_pairing.approve.success request_digest=" + SAME],
)


def self_test() -> int:
    """Every case names the verdict each invariant MUST produce. A green that
    cannot turn red is not evidence of anything."""
    cases = [
        ("good, tailnet", GOOD_TAILNET, True, 0,
         {"TAILNET-KEPT": "pass", "NO-SILENT-LAN": "pass",
          "NO-SPINNER": "pass", "FIRST-PHONE": "pass"}),
        ("good, pure LAN", GOOD_LAN, False, 0,
         {"LAN-WORKS": "pass", "NO-SPINNER": "pass", "FIRST-PHONE": "pass"}),
        ("bad, silent LAN downgrade", BAD_SILENT_LAN, True, 2,
         {"TAILNET-KEPT": "fail", "NO-SILENT-LAN": "fail"}),
        ("bad, endless spinner", BAD_SPINNER, True, 2,
         {"NO-SPINNER": "fail"}),
        ("bad, first phone deadlocked", BAD_FIRST_PHONE, True, 0,
         {"FIRST-PHONE": "fail", "NO-SPINNER": "fail"}),
        # An owner exists, so a Mac with no local session is a member without
        # authority — never an argument that the household is ownerless.
        ("owner exists, so first-phone does not apply", BAD_FIRST_PHONE, True, 1,
         {"FIRST-PHONE": "n/a"}),
        # And the same waiting run, captured for less than the approval
        # window, must not be called a spinner.
        ("short capture while awaiting approval", BAD_FIRST_PHONE, True, 0,
         {"NO-SPINNER": "n/a"}),
        ("bad, crossed profiles", BAD_CROSS_PROFILE, True, 2,
         {"PROFILE-ISOLATED": "fail"}),
        ("good, key present but locked", GOOD_CAPABILITY_LOCKED, True, 1,
         {"CAPABILITY-HONEST": "pass"}),
        ("bad, called locked missing", BAD_CAPABILITY_LIES, True, 1,
         {"CAPABILITY-HONEST": "fail"}),
        ("bad, a failed read reported as no_session", BAD_SESSION_LIES, True, 1,
         {"CAPABILITY-HONEST": "fail"}),
        ("good, the session really is absent", GOOD_SESSION_TRULY_ABSENT, True, 1,
         {"CAPABILITY-HONEST": "pass"}),
        ("good, both ends derived the same words", GOOD_WORDS_MATCH, True, 1,
         {"WORDS-MATCH": "pass"}),
        ("bad, the two ends derived different words", BAD_WORDS_DIFFER, True, 1,
         {"WORDS-MATCH": "fail"}),
        ("bad, only one end derived words", BAD_WORDS_ONE_SIDED, True, 1,
         {"WORDS-MATCH": "fail"}),
        ("neither end reached approval", GOOD_TAILNET, True, 1,
         {"WORDS-MATCH": "n/a"}),
        ("good, two requests logged in opposite order",
         GOOD_TWO_REQUESTS_ANY_ORDER, True, 1, {"WORDS-MATCH": "pass"}),
        ("bad, one request reviewed on the Mac only",
         BAD_ONE_REQUEST_UNREVIEWED, True, 1, {"WORDS-MATCH": "fail"}),
        # A run where nothing was ever attempted must not earn a pass for
        # "no claim crossed the profile line". Measured in the rehearsal of
        # 2026-09-05: the driver failed before touching anything and this
        # still reported ok.
        ("bad, engine accepted but the phone has no session",
         BAD_ENGINE_ONLY, False, 1, {"LAN-WORKS": "fail"}),
        ("bad, the engine's request digest is not the words",
         BAD_REQUEST_DIGEST_IS_NOT_WORDS, True, 1, {"WORDS-MATCH": "fail"}),
        ("no claim attempted at all", BAD_SPINNER, True, 1,
         {"PROFILE-ISOLATED": "n/a"}),
        ("a claim was attempted and stayed in profile",
         GOOD_CLAIM_IN_PROFILE, True, 1, {"PROFILE-ISOLATED": "pass"}),
    ]
    failures = 0
    # A capture longer than the approval window, so "waited past the deadline"
    # is distinguishable from "the capture simply ended". The one case that
    # needs the opposite says so with its own value.
    for label, transcript, has_tailnet, devices, expected in cases:
        captured = 30.0 if label.startswith("short capture") else 600.0
        got = {f.name: f.verdict
               for f in judge(transcript, has_tailnet, devices, captured)}
        for name, want in expected.items():
            if got.get(name) != want:
                print(f"  CALIBRATION FAILED  {label}: {name} "
                      f"expected {want}, got {got.get(name)}")
                failures += 1
        if not failures:
            print(f"  ok  {label}")
    if failures:
        print(f"\n{failures} calibration case(s) failed. "
              "This probe judges no real run until that is fixed.")
        return 1
    print("\ncalibration ok: it passes the good runs and fails every known defect.")
    return 0


# ──────────────────────────────── the run ────────────────────────────────


def run(args) -> int:
    guard_not_production(args.bootstrap_port)
    out_dir = args.out_dir or tempfile.mkdtemp(prefix="pairing-e2e-")
    os.makedirs(out_dir, exist_ok=True)
    mac_log = os.path.join(out_dir, "mac.log")

    devices_before = household_device_count(args.bootstrap_port)
    offset = engine_offset(args.engine_log)
    capture = start_mac_capture(mac_log, args.mac_process)
    print(f"capturing into {out_dir}")
    print(f"Dev household: device_count={devices_before}")
    print(f"\n>>> run the scenario NOW: {args.scenario}")
    print(f">>> {args.hold_secs}s until I read the tapes\n")

    try:
        time.sleep(args.hold_secs)
    finally:
        capture.terminate()
        try:
            capture.wait(timeout=5)
        except subprocess.TimeoutExpired:
            capture.kill()

    engine_lines = engine_tail(args.engine_log, offset)
    with open(mac_log, errors="replace") as handle:
        mac_lines = handle.read().splitlines()
    phone_lines = (collect_phone_log(args.udid, args.collect_minutes, out_dir)
                   if args.udid else ["<<no UDID given: the phone was not measured>>"])

    transcript = Transcript(mac=mac_lines, phone=phone_lines, engine=engine_lines)
    with open(os.path.join(out_dir, "transcript.json"), "w") as handle:
        json.dump(asdict(transcript), handle, indent=2)

    findings = judge(transcript, args.phone_has_tailnet, devices_before,
                     captured_secs=float(args.hold_secs))

    print(f"scenario: {args.scenario}")
    print(f"lines collected — Mac {len(mac_lines)}, phone {len(phone_lines)}, "
          f"engine {len(engine_lines)}\n")
    width = max(len(f.name) for f in findings)
    for finding in findings:
        mark = {"pass": "ok  ", "fail": "FAIL", "n/a": "  – "}[finding.verdict]
        print(f"  {mark} {finding.name.ljust(width)}  {finding.detail}")

    failed = [f for f in findings if f.verdict == "fail"]
    skipped = [f for f in findings if f.verdict == "n/a"]
    print(f"\n{len(findings) - len(failed) - len(skipped)} passed, "
          f"{len(failed)} failed, {len(skipped)} not applicable.")
    print(f"tapes in {out_dir}")

    # "I could not measure" and "I measured and it is broken" are different
    # answers that lead to different actions, and collapsing them wastes a
    # window. Only a run where EVERY invariant came back n/a is invalid; a run
    # with real failures measured something real.
    if len(skipped) == len(findings):
        print("\nNO invariant was exercised. This is not a green — "
              "it is a run that did not happen.")
        return 2
    return 1 if failed else 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true",
                        help="calibrate the judgement and exit; touches no device or engine")
    parser.add_argument("--scenario", default="pairing from scratch",
                        help="name of this run's scenario, for the report")
    parser.add_argument("--udid", help="test iPhone UDID; without it the phone is not measured")
    parser.add_argument("--phone-has-tailnet", action="store_true",
                        help="declare the Tailscale state ON THE PHONE for this scenario")
    parser.add_argument("--hold-secs", type=int, default=90)
    parser.add_argument("--collect-minutes", type=int, default=5)
    parser.add_argument("--bootstrap-port", type=int, default=DEV_BOOTSTRAP_PORT)
    parser.add_argument("--engine-log", default=DEV_ENGINE_LOG)
    parser.add_argument("--mac-process", default=DEV_APP_PROCESS)
    parser.add_argument("--out-dir")
    args = parser.parse_args()

    if args.self_test:
        return self_test()
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
