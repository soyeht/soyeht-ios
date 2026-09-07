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
  HOUSE-UNCHANGED   the engine's household directory has the same files with the
                    same bytes after the run as before it. Connecting to a Mac
                    writes nothing into the home — no request, no event, no
                    certificate. Judged from two snapshots, not from log lines.
  MAC-LOCAL         a home that already has an owner still authenticates a new
                    phone's PRESENCE on the Mac, over the Mac-local secret the
                    claim delivered, and NO household request is raised for it.
                    Presence only: opening a pane and attaching have their own
                    readback. The owner's production deadlock of 2026-09-07 was
                    a phone holding that secret and waiting for an owner.

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

DEV_HOUSE_DIR = os.path.expanduser(
    "~/Library/Application Support/SoyehtDev/household-state/household")
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
    # SHA-256 per file of the engine's household directory, before the run
    # and after it. None when the run did not snapshot (judge_dir without a
    # house.json, or the synthetic fixtures).
    house_before: dict[str, str] | None = None
    house_after: dict[str, str] | None = None

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
    """The PHONE finished: it has a session it can use.

    `pair_secret_stored` is what the app actually writes when it commits the
    pairing — MEASURED 2026-09-06 on a run that ended with "your Mac is yours"
    on screen while this returned false, because I was looking for markers the
    app does not emit. A verdict of "the phone never got a session" about a
    phone showing its paired home is the instrument talking, not the product.
    """
    return bool(t.phone_grep("pair_secret_stored")
                or t.phone_grep("pair.result=paired")
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
    # The address the phone actually SENT to, never the one it discovered.
    # `resolveDiscoveredMac` and `mac_browser.endpoint` are discovery: the
    # final selection can still change afterwards, so treating them as the
    # dialled address would attribute a LAN pairing to a run that sent
    # somewhere else entirely. [jaime]
    tried = (first_host(t.phone_grep("pair.confirm.post"), "host")
             or first_host(t.phone_grep("pair.request.post"), "host")
             or first_host(t.phone_grep("pair.endpoint source="), "host"))
    # NOT the endpoint on a `pairing.failed` line. For a domain error like
    # approvalTimedOut the view builds the failure with `house.engineURL`,
    # which is the house's address and not necessarily what the policy chose
    # inside the service — it may well have preferred tailnet. Using it as
    # proof of the send would attribute a LAN pairing to a request that went
    # somewhere else. `pair.request.post` is the only line taken from the
    # URLRequest actually handed to URLSession. [jaime]
    if tried is None:
        discovered = (t.phone_grep("resolveDiscoveredMac.entry")
                      or t.phone_grep("mac_browser.endpoint"))
        if discovered:
            return Finding("LAN-WORKS", "n/a",
                           "the phone discovered an address but nothing records "
                           "which one it SENT the request to; discovery is not "
                           "selection, so this cannot be judged from the tapes")
        return Finding("LAN-WORKS", "fail", "the phone never dialled any address")
    if classify(tried) != "lan":
        return Finding("LAN-WORKS", "fail",
                       f"no tailnet available, yet it tried {classify(tried)} ({tried})")
    if paired_outcome(t):
        return Finding("LAN-WORKS", "pass",
                       f"paired over the LAN ({tried}): the engine accepted "
                       "and the phone saved a session")
    if engine_accepted(t) and not phone_concluded(t):
        # Acceptance is not the phone's outcome: after approval it still has to
        # poll, validate the certificate and persist. Calling that divergence
        # while the phone is inside its own window would report a defect the
        # product does not have. Only a terminal failure or an expired deadline
        # settles it. [jaime]
        terminal = (t.phone_grep("pair.result=failed") or t.phone_grep("pairing.failed")
                    or t.phone_grep("expired") or t.engine_grep("expired"))
        if not terminal:
            return Finding("LAN-WORKS", "n/a",
                           f"the engine accepted over the LAN ({tried}) and the "
                           "phone is still inside its poll/validate/persist "
                           "window; neither a failure nor an expiry yet")
        return Finding("LAN-WORKS", "fail",
                       f"the engine accepted over the LAN ({tried}) and the "
                       "phone ended without a session — the two ends disagree "
                       "about whether this worked")
    failures = t.phone_grep("pairing.failed") or t.phone_grep("pair.result=failed")
    if failures:
        # Why it failed decides whose fault it is. `approvalExpired` means the
        # LAN carried the request to the engine and nobody approved in time —
        # that is not the local network failing.
        cause = re.search(r"cause=(\w+)", failures[0])
        reason = cause.group(1) if cause else "unknown"
        if reason in ("approvalExpired", "approvalTimedOut", "cancelled"):
            return Finding("LAN-WORKS", "n/a",
                           f"the LAN ({tried}) carried the request to the engine "
                           f"and the pairing ended as {reason}; nothing here is "
                           "the local network failing")
        return Finding("LAN-WORKS", "fail",
                       f"tried the LAN ({tried}) and the pairing failed: {reason}")
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


PERSISTED_CLASS_RE = re.compile(r"\bendpoint\.persisted\b.*?\bclass=(\w+)")


def inv_no_silent_lan(t: Transcript, phone_has_tailnet: bool) -> Finding:
    """A tailnet-capable phone must never WRITE DOWN a LAN address.

    Distinct from TAILNET-KEPT, which reads the address the phone dialled.
    The dialled address is one decision; the stored one is where every later
    reconnection starts, and storing the LAN address it happened to be
    reached on is precisely how a phone looks healthy at home and loses the
    Mac on the way out.

    MEASURED 2026-09-06: this was keyed on `endpoint.persisted`, a line no
    build has ever written — `grep -r endpoint.persisted` over the whole
    repository returned nothing. So every run reached "nothing was persisted"
    and reported n/a: an invariant that could not fail, guarding the defect
    it was written for by never looking at it. The product now logs the line
    (`PairedMacsStore.logPersistedEndpoint`), and a paired run that still
    records no address is a FAILURE here rather than a shrug — silence is the
    exact condition that hid this for as long as it did.
    """
    if not phone_has_tailnet:
        return Finding("NO-SILENT-LAN", "n/a", "only applies to a tailnet-capable phone")
    lines = t.phone_grep("endpoint.persisted")
    if not lines:
        if paired_outcome(t):
            return Finding("NO-SILENT-LAN", "fail",
                           "the run paired but the phone recorded no stored "
                           "address; either the build predates "
                           "endpoint.persisted or it saved without saying "
                           "what — both leave the LAN-fallback defect "
                           "invisible")
        return Finding("NO-SILENT-LAN", "n/a",
                       "nothing was persisted and nothing paired")
    # `class=` is decided by the app, on the same rule for every reader;
    # re-deriving it here from the address string would let the probe and the
    # product disagree about what "tailnet" means.
    kinds = [m.group(1) for line in lines
             if (m := PERSISTED_CLASS_RE.search(line))]
    saved = first_host(lines, "host")
    if not kinds:
        kinds = [classify(saved)] if saved else []
    if not kinds:
        return Finding("NO-SILENT-LAN", "fail",
                       "an endpoint.persisted line with neither class nor host")
    if "lan" in kinds:
        return Finding("NO-SILENT-LAN", "fail",
                       f"stored a LAN address ({saved}) on a tailnet-capable phone")
    return Finding("NO-SILENT-LAN", "pass",
                   f"stored {'/'.join(sorted(set(kinds)))} ({saved})")


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
    # `pairing.failed` is what the app actually emits; matching only
    # `pair.failed` missed a typed failure that was right there in the tape and
    # reported "left on the spinner" about a run that ended correctly. One word.
    # [jaime]
    ended = (t.phone_grep("pair.result=") or t.phone_grep("pairing.failed")
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


_DEVICE_ID = re.compile(r"\bdevice=([0-9A-Fa-f-]{36})")
_MAC_ID = re.compile(r"\bmac_id=([0-9A-Fa-f-]{36})")


def _ids(lines: list[str], pattern: re.Pattern[str]) -> set[str]:
    return {m.group(1).upper() for line in lines for m in [pattern.search(line)] if m}


_OWN_DEVICE_ID = re.compile(r"\bdevice_id=([0-9A-Fa-f-]{36})")


def inv_mac_local(t: Transcript, household_devices: int | None,
                  expected_device: str | None = None,
                  expected_mac: str | None = None) -> Finding:
    """A phone joining a home that already has an owner gets presence anyway.

    Two grants travel in the claim. The Mac-local secret opens presence and
    panes on that Mac and is verified by the Mac's own `PresenceSession`; the
    household certificate needs the owner person. On the owner's production
    Mac (2026-09-07) the owner could not act, and the phone — secret in hand —
    sat in `awaiting_approval`. This judges the path that does not: presence
    authenticated, and no household request raised for this phone.

    Presence only. `presence_authenticated` is the HMAC handshake; whether a
    pane then opens and attaches is a separate readback with its own lines.

    The Dev Mac has other clients, so the three markers are correlated by id
    rather than grepped globally: the Mac names the phone (`device=`) on both
    the secret it issued and the presence it authenticated, and the phone
    names the Mac (`mac_id=`) on both the HMAC it sent and the ack it accepted.
    Issued for A and authenticated for B is a neighbour's run, not this one.
    The engine's request line carries only a digest, so a household request
    is judged inside the capture window and cannot be pinned to a device.

    Each side closing on itself is still not one run ([jaime]): the Mac tape
    can hold a consistent pair A↔X while the phone tape holds B↔Y. So the
    subjects are named. The phone under test logs its own id when it mints
    one (`device_id_generated device_id=`, which a reset run always does),
    and that id must be the one the Mac issued to and authenticated; the Mac
    under test is `expected_mac` (its stored macId), and that must be the one
    the phone sent to and accepted. `expected_device` pins the phone when
    the tape did not mint an id.
    """
    if household_devices is None:
        return Finding("MAC-LOCAL", "n/a",
                       "the owner count was not read; cannot tell this from "
                       "the FIRST-PHONE case")
    if household_devices == 0:
        return Finding("MAC-LOCAL", "n/a",
                       "no owner is established; that is the FIRST-PHONE case")
    issued = _ids(t.mac_grep("direct_probe.local_pairing_created"), _DEVICE_ID)
    mac_authenticated = _ids(t.mac_grep("presence_authenticated"), _DEVICE_ID)
    sent_to = _ids(t.phone_grep("presence_hmac_sent"), _MAC_ID)
    phone_authenticated = _ids(t.phone_grep("presence_authenticated"), _MAC_ID)
    ceremony = (t.phone_grep("awaiting_approval")
                or t.engine_grep("device_pairing.request.success"))
    joined = t.engine_grep("pair_device.confirm.success")
    # The consumer's own verdict lines ([jaime], 57b2f54b): the success token
    # says whether the home was enrolled, and a claim-stage failure is typed.
    confirmed = t.phone_grep("existing_house.mac_connection_confirmed household_enrolled=false")
    enrolled = t.phone_grep("existing_house.mac_connection_confirmed household_enrolled=true")
    claim_failed = [line for line in t.phone_grep("pairing.failed") if "stage=claim" in line]

    if joined or enrolled:
        return Finding("MAC-LOCAL", "fail",
                       "this run joined the household; MAC-LOCAL measures the "
                       "path that reaches the Mac without an owner's approval")
    if claim_failed and not confirmed:
        cause = claim_failed[-1].split("pairing.failed", 1)[1].strip()
        return Finding("MAC-LOCAL", "fail",
                       f"the app gave up at the claim stage: {cause}")
    if ceremony and not (issued & mac_authenticated):
        return Finding("MAC-LOCAL", "fail",
                       "the phone raised a household request and waited on the "
                       "owner — the deadlock — instead of presenting the secret")
    if not issued:
        return Finding("MAC-LOCAL", "n/a",
                       "the Mac never issued a local secret in its claim; there "
                       "is nothing for this path to install")
    if not sent_to:
        return Finding("MAC-LOCAL", "fail",
                       "the Mac issued a secret and the phone never presented "
                       "one to any Mac")
    if not (issued & mac_authenticated):
        if mac_authenticated:
            return Finding("MAC-LOCAL", "fail",
                           "the Mac authenticated a different device than the "
                           "one it issued the secret to — a neighbour's "
                           "presence, not this run's")
        return Finding("MAC-LOCAL", "fail",
                       "the phone presented a secret and the Mac never "
                       "authenticated the device it issued one to")
    if not (sent_to & phone_authenticated):
        return Finding("MAC-LOCAL", "fail",
                       "the phone's accepted ack names a different Mac than the "
                       "one it sent the HMAC to")
    own = _ids(t.phone_grep("device_id_generated"), _OWN_DEVICE_ID)
    subject_device = {expected_device.upper()} if expected_device else own
    if subject_device and not (subject_device & issued & mac_authenticated):
        return Finding("MAC-LOCAL", "fail",
                       "the Mac's issued/authenticated device is not the phone "
                       "under test — a consistent pair, but not this run's")
    if expected_mac and expected_mac.upper() not in (sent_to & phone_authenticated):
        return Finding("MAC-LOCAL", "fail",
                       "the Mac the phone sent to and accepted is not the Mac "
                       "under test — a consistent pair, but not this run's")
    if not subject_device and not expected_mac:
        return Finding("MAC-LOCAL", "fail",
                       "no subject named: the phone minted no id in this tape "
                       "and no --mac-id/--device-id was given, so the four lines "
                       "cannot be tied to one pair")
    if ceremony:
        return Finding("MAC-LOCAL", "fail",
                       "presence authenticated, but a household request was "
                       "raised in the window — joining must stay a separate "
                       "gesture")
    if not confirmed:
        return Finding("MAC-LOCAL", "fail",
                       "presence authenticated, but the app never confirmed "
                       "the connection (no mac_connection_confirmed line)")
    return Finding("MAC-LOCAL", "pass",
                   "presence authenticated for the device the Mac issued the "
                   "secret to, no household request raised (presence only; "
                   "pane open/attach are their own readback)")


def inv_house_unchanged(t: Transcript) -> Finding:
    """Connecting to a Mac writes nothing into the engine's home.

    Two snapshots of the household directory — every file hashed — taken by
    the run before the phone moved and after the tapes were read. A joined
    household, a queued pair request, a rotated certificate all change bytes
    here; a Mac-local connection must not. Names only in the verdict: the
    files hold keys.
    """
    if t.house_before is None or t.house_after is None:
        return Finding("HOUSE-UNCHANGED", "n/a",
                       "the household directory was not snapshotted")
    before, after = t.house_before, t.house_after
    added = sorted(set(after) - set(before))
    removed = sorted(set(before) - set(after))
    changed = sorted(name for name in before if name in after and before[name] != after[name])
    if added or removed or changed:
        parts = []
        if changed: parts.append("changed " + ", ".join(changed))
        if added: parts.append("added " + ", ".join(added))
        if removed: parts.append("removed " + ", ".join(removed))
        return Finding("HOUSE-UNCHANGED", "fail",
                       "the home was written during the run: " + "; ".join(parts))
    return Finding("HOUSE-UNCHANGED", "pass",
                   f"{len(before)} files, same bytes before and after")


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


def _last_index(lines: list[str], needle: str) -> int:
    found = [i for i, line in enumerate(lines) if needle in line]
    return found[-1] if found else -1


def _advert_live_at(lines: list[str], index: int) -> bool:
    """Was an advert registered by position `index`, in EITHER vocabulary?

    The fix removes the word `skipped` and adds `bonjour.reconciled` with
    counts. Keying on the old name would make this invariant pass on the new
    build because a string disappeared, not because the defect did — [jaime]
    asked for the negative that stops exactly that, and he was right to.
    """
    published = _last_index(lines[:index + 1], "bonjour.published")
    # `registered_count=0` is the new way of saying "nothing is advertised".
    withdrawn = max(
        _last_index(lines[:index + 1], "bonjour.skipped"),
        _last_index(lines[:index + 1], "bonjour.unregistered"),
        max((i for i, l in enumerate(lines[:index + 1])
             if "bonjour.reconciled" in l and "registered_count=0" in l),
            default=-1),
    )
    return published > withdrawn


def inv_advert_follows_window(t: Transcript) -> Finding:
    """The advert has to follow the window, both ways, with no restart.

    MEASURED 2026-09-06 on the QA Mac, same binary, same machine, same network:

        13:44:16  bonjour.published     one startup published
        13:51:51  bonjour.skipped       the next one skipped
        13:51 .. 13:55  the window opened and bound ten times,
                        and nothing was ever advertised again

    The publisher filtered its targets once at startup, so widening the
    listener later added a bind and never a record. A Mac that boots with the
    window closed and no tailnet stays invisible until someone restarts its
    engine — no test rig needed, just a person opening the app after a reboot.

    This checks the PROPERTY and never the vocabulary: after a window opens
    there must be a live advert, and after it closes with nothing else to
    advertise the record must be gone. `bonjour.ready bound_count=0` followed
    by an open window and no publish fails just as `skipped` did.

    A caveat that belongs in the verdict, not in a footnote: `registered_count`
    proves the backend returned, never that a phone can see it. Remote
    observation with `dns-sd` from another machine stays the real proof of an
    advert, and this invariant does not replace it. [jaime]
    """
    engine = t.engine
    opens = [i for i, l in enumerate(engine)
             if "local_network_visibility.opened" in l
             or "household_listener.pairing_window_bound" in l]
    if not opens:
        return Finding("ADVERT-FOLLOWS-WINDOW", "n/a",
                       "no pairing window was opened in this run")
    # A tape with no publisher lines at all has nothing to judge — the advert
    # may have been registered before the capture started. Reporting failure
    # there blames the product for the moment I chose to begin recording, and
    # that is exactly what happened when I truncated the log mid-session.
    if not any("bonjour." in line for line in engine):
        return Finding("ADVERT-FOLLOWS-WINDOW", "n/a",
                       "the capture holds no publisher lines; the advert may "
                       "predate it, so this cannot be judged from this tape")

    last_open = opens[-1]
    if not _advert_live_at(engine, len(engine) - 1) and last_open < len(engine):
        # Was anything advertised AFTER the last open? Look forward from it.
        after = engine[last_open:]
        if not any("bonjour.published" in l for l in after):
            return Finding("ADVERT-FOLLOWS-WINDOW", "fail",
                           "a window opened and no advert followed it; this Mac "
                           "is invisible until its engine restarts")

    closes = [i for i, l in enumerate(engine)
              if "pairing_window=closed" in l or 'pairing_window":"closed' in l]
    if closes and closes[-1] > last_open:
        # Closing withdraws the LAN, never the whole home. A tailnet advert is
        # legitimate with the window closed: someone away from the house still
        # has to reach their Mac. Failing on any live registration would have
        # demanded that closing the sheet make the Mac vanish entirely, which
        # is a rule nobody asked for and would break the case the tailnet
        # exists to serve. [jaime]
        lan_after_close = [
            l for l in engine[closes[-1]:]
            if "bonjour.published" in l and "interface_class=lan" in l
        ]
        residual_lan = [
            l for l in engine[closes[-1]:]
            if "bonjour.reconciled" in l and "pairing_window=closed" in l
            and "lan" in l.lower() and "registered_count=0" not in l
        ]
        if lan_after_close or residual_lan:
            return Finding("ADVERT-FOLLOWS-WINDOW", "fail",
                           "the window closed and a LAN advert is still "
                           "registered; the home stays discoverable on the "
                           "Wi-Fi after the person dismissed the sheet")
        return Finding("ADVERT-FOLLOWS-WINDOW", "pass",
                       "the advert followed the window open and the LAN was "
                       "withdrawn on close, with no restart")
    return Finding("ADVERT-FOLLOWS-WINDOW", "pass",
                   "the advert followed the window without a restart")


def judge(t: Transcript, phone_has_tailnet: bool,
          household_devices: int | None,
          captured_secs: float | None = None, *,
          expected_device: str | None = None,
          expected_mac: str | None = None) -> list[Finding]:
    return [
        inv_tailnet_kept(t, phone_has_tailnet),
        inv_lan_works(t, phone_has_tailnet),
        inv_no_silent_lan(t, phone_has_tailnet),
        inv_profile_isolated(t),
        inv_no_spinner(t, captured_secs),
        inv_first_phone(t, household_devices),
        inv_capability_honest(t),
        inv_words_match(t),
        inv_advert_follows_window(t),
        inv_mac_local(t, household_devices, expected_device, expected_mac),
        inv_house_unchanged(t),
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


def house_snapshot(directory: str | None) -> dict[str, str] | None:
    """SHA-256 of every file under the engine's household directory, keyed by
    relative path. None when there is no such directory to look at."""
    if not directory or not os.path.isdir(directory):
        return None
    import hashlib
    snapshot = {}
    for root, _dirs, files in os.walk(directory):
        for name in files:
            path = os.path.join(root, name)
            with open(path, "rb") as handle:
                snapshot[os.path.relpath(path, directory)] = hashlib.sha256(handle.read()).hexdigest()
    return snapshot


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
           "endpoint.persisted mac_id=M1 host=100.64.0.10 class=tailnet",
           "pair.result=paired"],
    engine=["pair_device.confirm.success elapsed_ms=180"],
)

GOOD_LAN = Transcript(
    mac=["direct_probe.notified iphone=http://192.168.1.50:8092/ "
         "mac=http://192.168.1.20:8101"],
    phone=["pair.endpoint source=claim host=192.168.1.20 port=8101",
           "pair.confirm.post host=192.168.1.20 port=8101",
           "endpoint.persisted mac_id=M1 host=192.168.1.20 class=lan",
           "pair.result=paired"],
    engine=["pair_device.confirm.success elapsed_ms=210"],
)

BAD_SILENT_LAN = Transcript(
    mac=["direct_probe.notified mac=http://100.64.0.10:8101"],
    phone=["pair.endpoint source=reached host=192.168.1.20 port=8101",
           "pair.confirm.post host=192.168.1.20 port=8101",
           "endpoint.persisted mac_id=M1 host=192.168.1.20 class=lan",
           "pair.result=paired"],
    engine=["pair_device.confirm.success"],
)

# The shape that reported "n/a" for months: a phone that paired and left no
# record of what it stored. Silence here is a failure, not an exemption —
# that shrug is exactly what let a non-existent log line pass for a guard.
PAIRED_BUT_STORED_NOTHING = Transcript(
    mac=["direct_probe.notified mac=http://100.64.0.10:8101"],
    phone=["pair.endpoint source=reached host=100.64.0.10 port=8101",
           "pair.confirm.post host=100.64.0.10 port=8101",
           "pair_secret_stored mac_id=M1"],
    engine=["pair_device.confirm.success elapsed_ms=190"],
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

GOOD_MAC_LOCAL = Transcript(
    mac=["direct_probe.local_pairing_created device=9E2C3A1B-0000-4000-8000-00000000000A host=192.168.1.20",
         "presence_authenticated device=9E2C3A1B-0000-4000-8000-00000000000A"],
    phone=["device_id_generated device_id=9E2C3A1B-0000-4000-8000-00000000000A",
           "pair.endpoint source=claim host=192.168.1.20 port=8101",
           "presence_hmac_sent mac_id=5D0F7C2E-0000-4000-8000-000000000001",
           "presence_authenticated mac_id=5D0F7C2E-0000-4000-8000-000000000001",
           "existing_house.mac_connection_confirmed household_enrolled=false"],
    engine=[],
    house_before={"household_record.cbor": "aa", "owner_events/log.cbor": "bb"},
    house_after={"household_record.cbor": "aa", "owner_events/log.cbor": "bb"},
)

# The app reached the Mac and ALSO enrolled the home under it.
BAD_MAC_LOCAL_ENROLLED = Transcript(
    mac=["direct_probe.local_pairing_created device=9E2C3A1B-0000-4000-8000-00000000000A host=192.168.1.20",
         "presence_authenticated device=9E2C3A1B-0000-4000-8000-00000000000A"],
    phone=["presence_hmac_sent mac_id=5D0F7C2E-0000-4000-8000-000000000001",
           "presence_authenticated mac_id=5D0F7C2E-0000-4000-8000-000000000001",
           "existing_house.mac_connection_confirmed household_enrolled=true"],
    engine=[],
)

# The card was on screen, the claim never came, and the app said so.
BAD_MAC_LOCAL_CLAIM_TIMEOUT = Transcript(
    mac=[],
    phone=["pairing.failed stage=claim cause=network(timeout) endpoint=http://192.168.1.20:8101/"],
    engine=[],
)

# A run that wrote into the home: the owner-events log grew.
BAD_HOUSE_WRITTEN = Transcript(
    mac=[], phone=[], engine=[],
    house_before={"household_record.cbor": "aa", "owner_events/log.cbor": "bb"},
    house_after={"household_record.cbor": "aa", "owner_events/log.cbor": "cc",
                 "owner_events/new.cbor": "dd"},
)

# The owner's production run: the secret was issued, and the phone raised a
# household request and waited instead of presenting it.
BAD_MAC_LOCAL_DEADLOCK = Transcript(
    mac=["direct_probe.local_pairing_created device=9E2C3A1B-0000-4000-8000-00000000000A host=192.168.1.20"],
    phone=["pair.endpoint source=claim host=192.168.1.20 port=8101",
           "awaiting_approval"],
    engine=["device_pairing.request.success request_digest=abc"],
)

# Presence came up, but the phone ALSO fired a household request. Reaching the
# Mac is right; starting the ceremony underneath it is the deadlock's seed.
BAD_MAC_LOCAL_CEREMONY_ANYWAY = Transcript(
    mac=["direct_probe.local_pairing_created device=9E2C3A1B-0000-4000-8000-00000000000A host=192.168.1.20",
         "presence_authenticated device=9E2C3A1B-0000-4000-8000-00000000000A"],
    phone=["presence_hmac_sent mac_id=5D0F7C2E-0000-4000-8000-000000000001",
           "presence_authenticated mac_id=5D0F7C2E-0000-4000-8000-000000000001"],
    engine=["device_pairing.request.success request_digest=abc"],
)

# A neighbour's green: the Dev Mac has other clients. The secret went to phone
# A; the presence the Mac authenticated in the window belongs to phone B.
BAD_MAC_LOCAL_NEIGHBOUR = Transcript(
    mac=["direct_probe.local_pairing_created device=9E2C3A1B-0000-4000-8000-00000000000A host=192.168.1.20",
         "presence_authenticated device=9E2C3A1B-0000-4000-8000-00000000000B"],
    phone=["presence_hmac_sent mac_id=5D0F7C2E-0000-4000-8000-000000000001",
           "presence_authenticated mac_id=5D0F7C2E-0000-4000-8000-000000000001"],
    engine=[],
)

# Two pairs, each consistent with itself, neither the pair under test: the
# Mac tape shows phone A issued and authenticated; the phone tape is phone
# B's, sent to and accepted by Mac 2. Every per-side intersection is
# non-empty. Only naming the subjects tells them apart.
BAD_MAC_LOCAL_TWO_PAIRS = Transcript(
    mac=["direct_probe.local_pairing_created device=9E2C3A1B-0000-4000-8000-00000000000A host=192.168.1.20",
         "presence_authenticated device=9E2C3A1B-0000-4000-8000-00000000000A"],
    phone=["device_id_generated device_id=9E2C3A1B-0000-4000-8000-00000000000B",
           "presence_hmac_sent mac_id=5D0F7C2E-0000-4000-8000-000000000002",
           "presence_authenticated mac_id=5D0F7C2E-0000-4000-8000-000000000002",
           "existing_house.mac_connection_confirmed household_enrolled=false"],
    engine=[],
)

# The phone sent its HMAC to one Mac and accepted an ack from another.
BAD_MAC_LOCAL_WRONG_MAC = Transcript(
    mac=["direct_probe.local_pairing_created device=9E2C3A1B-0000-4000-8000-00000000000A host=192.168.1.20",
         "presence_authenticated device=9E2C3A1B-0000-4000-8000-00000000000A"],
    phone=["presence_hmac_sent mac_id=5D0F7C2E-0000-4000-8000-000000000001",
           "presence_authenticated mac_id=5D0F7C2E-0000-4000-8000-000000000002"],
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
    phone=["pair.confirm.post host=192.168.1.20 port=8101",
           "pair.result=failed"],
    engine=["device_pairing.approve.success request_digest=" + "c" * 64],
)

# The engine's own correlation digest must not be mistaken for the words.
BAD_REQUEST_DIGEST_IS_NOT_WORDS = Transcript(
    mac=["owner_capability=proven"],
    phone=["pairing_review_digest=" + SAME],
    engine=["device_pairing.request.success request_digest=" + SAME,
            "device_pairing.approve.success request_digest=" + SAME],
)


PENDING_ENGINE_ACCEPTED = Transcript(
    mac=[],
    phone=["pair.confirm.post host=192.168.1.20 port=8101"],
    engine=["device_pairing.approve.success request_digest=" + "d" * 64],
)

DISCOVERY_ONLY = Transcript(
    mac=[],
    phone=["resolveDiscoveredMac.entry engines=http://192.168.1.20:8101"],
    engine=[],
)


# The shape that made this probe report a spinner on a run that ended
# correctly: a typed failure under the name the app really uses.
GOOD_TYPED_EXPIRY = Transcript(
    mac=[],
    phone=["pair.request.post host=192.168.1.20 port=8101",
           "pairing.failed stage=request endpoint=http://192.168.1.20:8101 "
           "cause=approvalExpired"],
    engine=["device_pairing.request.success request_digest=" + "e" * 64],
)

# The same expiry WITHOUT a record of the send. The failure line carries an
# endpoint, but for a domain error it is the house URL — so this must stay
# unjudgeable rather than credit the LAN with a request it cannot prove.
EXPIRY_WITHOUT_SEND_RECORD = Transcript(
    mac=[],
    phone=["resolveDiscoveredMac.entry engines=http://192.168.1.20:8101",
           "pairing.failed stage=request endpoint=http://192.168.1.20:8101 "
           "cause=approvalExpired"],
    engine=["device_pairing.request.success request_digest=" + "f" * 64],
)


# The exact shape measured on the QA Mac: published once, then a restart that
# skipped, then windows opening forever with no advert.
BAD_SKIP_IS_TERMINAL = Transcript(
    mac=[],
    phone=[],
    engine=["bonjour.published", "bonjour.ready",
            "local_network_visibility.opened",
            "bonjour.unregistered", "bonjour.shutdown_complete",
            "bonjour.skipped",
            "local_network_visibility.opened",
            "household_listener.pairing_window_bound",
            "local_network_visibility.opened"],
)

GOOD_ADVERT_FOLLOWS = Transcript(
    mac=[],
    phone=[],
    engine=["bonjour.skipped",
            "local_network_visibility.opened",
            "household_listener.pairing_window_bound",
            "bonjour.published", "bonjour.ready"],
)


# The fix removes the word `skipped`. This is the same defect wearing the new
# vocabulary, and it must still fail — otherwise the invariant would pass
# because a string went away. [jaime]
BAD_READY_ZERO_THEN_WINDOW = Transcript(
    mac=[], phone=[],
    engine=["bonjour.ready bound_count=0 pairing_window=closed",
            "local_network_visibility.opened",
            "household_listener.pairing_window_bound",
            "local_network_visibility.opened"],
)

GOOD_RECONCILED_ON_OPEN = Transcript(
    mac=[], phone=[],
    engine=["bonjour.ready bound_count=0 pairing_window=closed",
            "local_network_visibility.opened",
            "bonjour.published",
            "bonjour.reconciled target_count=1 registered_count=1 "
            "retry_registration=false pairing_window=open"],
)

GOOD_WITHDRAWN_ON_CLOSE = Transcript(
    mac=[], phone=[],
    engine=["local_network_visibility.opened",
            "bonjour.published",
            "bonjour.reconciled target_count=1 registered_count=1 pairing_window=open",
            "bonjour.reconciled target_count=0 registered_count=0 pairing_window=closed"],
)

# Without a transport this case was ambiguous: a live registration after a
# close is a leak only if it is the LAN. Saying `lan` out loud is what the
# fixture always meant, and leaving it implicit made the calibration pass for
# the wrong reason once the rule learned to tell the two apart.
BAD_STILL_ADVERTISED_AFTER_CLOSE = Transcript(
    mac=[], phone=[],
    engine=["local_network_visibility.opened",
            "bonjour.published interface_class=lan address=192.168.1.20:8101",
            "bonjour.reconciled target_count=1 registered_count=1 "
            "interface_class=lan pairing_window=closed"],
)


# Closing withdraws the LAN and leaves the tailnet. Both of these close the
# window; only one of them is a leak.
GOOD_TAILNET_SURVIVES_CLOSE = Transcript(
    mac=[], phone=[],
    engine=["local_network_visibility.opened",
            "bonjour.published interface_class=lan address=192.168.1.20:8101",
            "bonjour.published interface_class=tailnet address=100.64.0.10:8101",
            "bonjour.reconciled target_count=1 registered_count=1 pairing_window=closed"],
)

BAD_LAN_SURVIVES_CLOSE = Transcript(
    mac=[], phone=[],
    engine=["local_network_visibility.opened",
            "bonjour.published interface_class=lan address=192.168.1.20:8101",
            "bonjour.reconciled target_count=1 registered_count=1 pairing_window=closed",
            "bonjour.published interface_class=lan address=192.168.1.20:8101"],
)


# A run that concluded using the marker the app really writes.
GOOD_PHONE_STORED_SECRET = Transcript(
    mac=[], phone=["pair.confirm.post host=192.168.1.20 port=8101",
                   "pair_secret_stored mac_id=abc"],
    engine=["device_pairing.approve.success request_digest=" + "a" * 64],
)

# Window opened, but the tape starts after the advert was already registered.
NO_PUBLISHER_LINES_AT_ALL = Transcript(
    mac=[], phone=[],
    engine=["local_network_visibility.opened",
            "household_listener.pairing_window_bound"],
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
        ("bad, paired but stored nothing", PAIRED_BUT_STORED_NOTHING, True, 2,
         {"NO-SILENT-LAN": "fail"}),
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
        ("good, owned home authenticates the phone's presence", GOOD_MAC_LOCAL, False, 1,
         {"MAC-LOCAL": "pass"}),
        ("bad, owned home: phone waits on the owner instead",
         BAD_MAC_LOCAL_DEADLOCK, False, 1, {"MAC-LOCAL": "fail"}),
        ("bad, presence up but a household request raised anyway",
         BAD_MAC_LOCAL_CEREMONY_ANYWAY, False, 1, {"MAC-LOCAL": "fail"}),
        ("bad, two consistent pairs, neither under test",
         BAD_MAC_LOCAL_TWO_PAIRS, False, 1, {"MAC-LOCAL": "fail"}),
        ("bad, a neighbour's presence under this run's secret",
         BAD_MAC_LOCAL_NEIGHBOUR, False, 1, {"MAC-LOCAL": "fail"}),
        ("bad, HMAC to one Mac, ack from another",
         BAD_MAC_LOCAL_WRONG_MAC, False, 1, {"MAC-LOCAL": "fail"}),
        ("no owner, so MAC-LOCAL does not apply", GOOD_MAC_LOCAL, False, 0,
         {"MAC-LOCAL": "n/a"}),
        ("owner count unread: MAC-LOCAL cannot borrow the scenario",
         GOOD_MAC_LOCAL, False, None, {"MAC-LOCAL": "n/a"}),
        ("bad, reached the Mac and enrolled the home under it",
         BAD_MAC_LOCAL_ENROLLED, False, 1, {"MAC-LOCAL": "fail"}),
        ("bad, the claim never came and the app said so",
         BAD_MAC_LOCAL_CLAIM_TIMEOUT, False, 1, {"MAC-LOCAL": "fail"}),
        ("good, the home has the same bytes after the run",
         GOOD_MAC_LOCAL, False, 1, {"HOUSE-UNCHANGED": "pass"}),
        ("bad, the run wrote into the home",
         BAD_HOUSE_WRITTEN, False, 1, {"HOUSE-UNCHANGED": "fail"}),
        ("no snapshot, so HOUSE-UNCHANGED cannot be judged",
         BAD_MAC_LOCAL_ENROLLED, False, 1, {"HOUSE-UNCHANGED": "n/a"}),
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
        ("bad, engine accepted and the phone ended with no session",
         BAD_ENGINE_ONLY, False, 1, {"LAN-WORKS": "fail"}),
        ("engine accepted, phone still inside its window",
         PENDING_ENGINE_ACCEPTED, False, 1, {"LAN-WORKS": "n/a"}),
        ("discovered an address but no record of the send",
         DISCOVERY_ONLY, False, 1, {"LAN-WORKS": "n/a"}),
        ("bad, the engine's request digest is not the words",
         BAD_REQUEST_DIGEST_IS_NOT_WORDS, True, 1, {"WORDS-MATCH": "fail"}),
        ("good, ended with a typed expiry rather than a spinner",
         GOOD_TYPED_EXPIRY, False, 1,
         {"NO-SPINNER": "pass", "LAN-WORKS": "n/a"}),
        ("expiry with no record of the send stays unjudgeable",
         EXPIRY_WITHOUT_SEND_RECORD, False, 1,
         {"NO-SPINNER": "pass", "LAN-WORKS": "n/a"}),
        ("bad, skip at startup is never recovered",
         BAD_SKIP_IS_TERMINAL, True, 1, {"ADVERT-FOLLOWS-WINDOW": "fail"}),
        ("good, the advert follows a window opened after a skip",
         GOOD_ADVERT_FOLLOWS, True, 1, {"ADVERT-FOLLOWS-WINDOW": "pass"}),
        ("bad, ready with zero then a window and no publish",
         BAD_READY_ZERO_THEN_WINDOW, True, 1, {"ADVERT-FOLLOWS-WINDOW": "fail"}),
        ("good, reconciled on open after a zero start",
         GOOD_RECONCILED_ON_OPEN, True, 1, {"ADVERT-FOLLOWS-WINDOW": "pass"}),
        ("good, withdrawn on close", GOOD_WITHDRAWN_ON_CLOSE, True, 1,
         {"ADVERT-FOLLOWS-WINDOW": "pass"}),
        ("bad, still advertised after the window closed",
         BAD_STILL_ADVERTISED_AFTER_CLOSE, True, 1,
         {"ADVERT-FOLLOWS-WINDOW": "fail"}),
        ("good, tailnet advert survives closing the window",
         GOOD_TAILNET_SURVIVES_CLOSE, True, 1, {"ADVERT-FOLLOWS-WINDOW": "pass"}),
        ("bad, LAN advert survives closing the window",
         BAD_LAN_SURVIVES_CLOSE, True, 1, {"ADVERT-FOLLOWS-WINDOW": "fail"}),
        ("good, the phone stored its pairing secret",
         GOOD_PHONE_STORED_SECRET, False, 1, {"LAN-WORKS": "pass"}),
        ("a tape with no publisher lines cannot be judged",
         NO_PUBLISHER_LINES_AT_ALL, True, 1, {"ADVERT-FOLLOWS-WINDOW": "n/a"}),
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
    house_before = house_snapshot(args.house_dir)
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

    transcript = Transcript(mac=mac_lines, phone=phone_lines, engine=engine_lines,
                            house_before=house_before,
                            house_after=house_snapshot(args.house_dir))
    with open(os.path.join(out_dir, "transcript.json"), "w") as handle:
        json.dump(asdict(transcript), handle, indent=2)

    findings = judge(transcript, args.phone_has_tailnet, devices_before,
                     captured_secs=float(args.hold_secs),
                     expected_device=args.device_id, expected_mac=args.mac_id)

    return report(findings, args.scenario, out_dir, transcript)


def report(findings: list[Finding], scenario: str, out_dir: str,
           transcript: Transcript) -> int:
    """Prints the verdict and returns the exit code, for either entry point."""
    print(f"scenario: {scenario}")
    print(f"lines collected — Mac {len(transcript.mac)}, "
          f"phone {len(transcript.phone)}, engine {len(transcript.engine)}\n")
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


def judge_dir(args) -> int:
    """Judges tapes that already exist, instead of capturing new ones.

    `run` starts its own capture and then waits, which is right when the probe
    drives the run itself. But a run driven by hand — or one whose tapes were
    kept from an earlier session — leaves three files and no verdict, and
    re-driving the device just to re-read them costs a household reset and a
    re-pair. Worse, it invites judging by eye, which is how ten runs got
    reported wrong before this probe existed.
    """
    directory = args.judge_dir

    def lines(name: str) -> list[str]:
        path = os.path.join(directory, name)
        if not os.path.exists(path):
            return []
        with open(path, errors="replace") as handle:
            return handle.read().splitlines()

    house_path = os.path.join(directory, "transcript.json")
    house_before = house_after = None
    if os.path.exists(house_path):
        with open(house_path) as handle:
            saved = json.load(handle)
        house_before, house_after = saved.get("house_before"), saved.get("house_after")
    transcript = Transcript(mac=lines("mac.log"), phone=lines("phone.log"),
                            engine=lines("engine.log"),
                            house_before=house_before, house_after=house_after)
    if not (transcript.mac or transcript.phone or transcript.engine):
        print(f"refusing: no mac.log, phone.log or engine.log in {directory}. "
              "An empty transcript makes every invariant report n/a, which "
              "reads like a clean run.")
        return 1
    findings = judge(transcript, phone_has_tailnet=args.phone_has_tailnet,
                     expected_device=args.device_id, expected_mac=args.mac_id,
                     household_devices=args.devices,
                     captured_secs=args.captured_secs)
    return report(findings, args.scenario, directory, transcript)


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
    parser.add_argument("--mac-id", help="macId of the Mac under test (its "
                        "stored com.soyeht.mac.macId); MAC-LOCAL requires it on "
                        "the phone's sent and accepted lines")
    parser.add_argument("--device-id", help="deviceID of the phone under test, "
                        "when its tape did not mint one")
    parser.add_argument("--house-dir", default=DEV_HOUSE_DIR,
                        help="engine household directory to snapshot before "
                             "and after, for HOUSE-UNCHANGED")
    parser.add_argument("--mac-process", default=DEV_APP_PROCESS)
    parser.add_argument("--out-dir")
    parser.add_argument("--judge-dir",
                        help="judge mac.log / phone.log / engine.log already "
                             "in this directory instead of capturing new ones")
    parser.add_argument("--devices", type=int, default=0,
                        help="with --judge-dir: the household's device_count "
                             "at the time the tapes were taken")
    parser.add_argument("--captured-secs", type=float,
                        help="with --judge-dir: how long the capture ran, so "
                             "NO-SPINNER can tell waiting from waiting forever")
    args = parser.parse_args()

    if args.self_test:
        return self_test()
    if args.judge_dir:
        return judge_dir(args)
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
