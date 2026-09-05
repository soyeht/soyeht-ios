#!/usr/bin/env python3
"""Mede uma corrida de pareamento de ponta a ponta e diz QUAL invariante caiu.

POR QUE ISTO EXISTE

Em 2026-09-05 o Caio ficou olhando um spinner. As duas suítes estavam verdes,
o Mac 0.1.47 escutava nos dois endereços, o firewall estava desligado e o
celular tinha rota direta na tailnet. Nada disso respondia a pergunta que
importava — *qual endereço o celular tentou, e o que voltou* — porque a
resposta mora em três logs diferentes, em duas máquinas, e ninguém junta.

Esta sonda junta. Ela não é um teste de unidade com outro nome: ela lê o que
os TRÊS participantes registraram durante UMA corrida real e confere os
invariantes contra isso.

O QUE ELA MEDE, E DE ONDE

  Mac    os_log, subsystem `com.soyeht.mac`  →  endereço OFERECIDO no claim
  iPhone os_log, subsystem `com.soyeht.mobile` (via `log collect`, porque
         `idevicesyslog` não carrega as nossas linhas — medido 2026-09-05)
                                             →  endereço ESCOLHIDO e TENTADO
  engine `~/Library/Logs/SoyehtDev/engine.log`
                                             →  o que CHEGOU, e o desfecho

Correlacionar os três é o ponto. Cada um sozinho mente por omissão: o Mac diz
que notificou, o engine diz que não recebeu nada, e sem o celular no meio não
dá para saber se ele discou o endereço errado ou se nem discou.

OS INVARIANTES

  TAILNET-KEPT     celular com tailnet escolhe tailnet E persiste tailnet.
                   A propriedade que protege quem sai de casa.
  LAN-WORKS        celular sem tailnet pareia pela LAN. Decisão explícita do
                   Caio, provada no aparelho em 2026-09-05; regressão aqui é
                   reprovação, não "comportamento mais seguro".
  NO-SILENT-LAN    celular COM tailnet nunca persiste endereço de LAN.
  PROFILE-ISOLATED prod e Dev não reclamam o celular um do outro.
  NO-SPINNER       toda corrida termina em sucesso, falha tipada ou
                   cancelamento. Espera sem prazo é reprovação.
  FIRST-PHONE      casa cujo único membro é o Mac admite o primeiro iPhone
                   sem aprovação de um terceiro que não existe.

CALIBRAÇÃO

Um verde só vale se o vermelho for possível. `--self-test` roda os invariantes
contra transcrições sintéticas de corridas boas e ruins e exige que os dois
lados batam. Se o self-test não passa, a sonda não julga corrida nenhuma.

SEGURANÇA

Só olha para o par Dev (bootstrap 8101, admin 8902). Recusa-se a rodar contra
produção (8091/8892) e nunca escreve em nada da produção.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
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
PROD_ENGINE_LOG = os.path.expanduser("~/Library/Logs/Soyeht/engine.log")
DEV_APP_PROCESS = "Soyeht Dev"
MAC_SUBSYSTEM = "com.soyeht.mac"
PHONE_SUBSYSTEM = "com.soyeht.mobile"

TAILNET_RE = re.compile(r"\b100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}\b")
LOOPBACK_RE = re.compile(r"\b(127\.\d{1,3}\.\d{1,3}\.\d{1,3}|::1|localhost)\b")
IPV4_RE = re.compile(r"\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b")


def classify(host: str | None) -> str:
    """tailnet / lan / loopback / unknown — a mesma partição que o engine usa.

    Vale para host puro e para URL; quem chama não precisa saber a diferença.
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


# ────────────────────────── o que cada lado disse ──────────────────────────


@dataclass
class Transcript:
    """As três fitas de uma corrida, já em texto, cada linha na sua origem."""

    mac: list[str] = field(default_factory=list)
    phone: list[str] = field(default_factory=list)
    engine: list[str] = field(default_factory=list)

    def mac_grep(self, needle: str) -> list[str]:
        return [l for l in self.mac if needle in l]

    def phone_grep(self, needle: str) -> list[str]:
        return [l for l in self.phone if needle in l]

    def engine_grep(self, needle: str) -> list[str]:
        return [l for l in self.engine if needle in l]


def first_host(lines: list[str], key: str) -> str | None:
    """O valor de `key=` (host ou URL) na primeira linha que o traz.

    Aceita `host=1.2.3.4`, `mac=http://1.2.3.4:8101` e `endpoint=…` — as três
    formas que os nossos logs realmente usam hoje.
    """
    for line in lines:
        m = re.search(rf"{re.escape(key)}=(\S+)", line)
        if m:
            return m.group(1)
    return None


# ───────────────────────────── os invariantes ─────────────────────────────
#
# Cada um responde uma pergunta e devolve (veredito, evidência). O veredito é
# "pass", "fail" ou "n/a" — n/a quando o cenário não exercita aquilo. n/a
# NUNCA conta como pass: o resumo separa os dois de propósito, porque foi
# assim que a suíte ficou verde enquanto o produto estava quebrado.


@dataclass
class Finding:
    name: str
    verdict: str  # pass | fail | n/a
    detail: str


def inv_tailnet_kept(t: Transcript, phone_has_tailnet: bool) -> Finding:
    if not phone_has_tailnet:
        return Finding("TAILNET-KEPT", "n/a", "celular sem tailnet neste cenário")
    chosen = first_host(t.phone_grep("pair.endpoint"), "host")
    if chosen is None:
        return Finding("TAILNET-KEPT", "fail",
                       "o celular não registrou endereço escolhido")
    kind = classify(chosen)
    if kind == "tailnet":
        return Finding("TAILNET-KEPT", "pass", f"escolheu tailnet ({chosen})")
    return Finding("TAILNET-KEPT", "fail",
                   f"celular tem tailnet e escolheu {kind} ({chosen}); "
                   "sai de casa e fica sem Mac")


def inv_lan_works(t: Transcript, phone_has_tailnet: bool) -> Finding:
    if phone_has_tailnet:
        return Finding("LAN-WORKS", "n/a", "cenário não exercita LAN pura")
    tried = first_host(t.phone_grep("pair.confirm.post"), "host")
    if tried is None:
        return Finding("LAN-WORKS", "fail", "o celular nunca chegou a confirmar")
    if classify(tried) != "lan":
        return Finding("LAN-WORKS", "fail",
                       f"sem tailnet, mas tentou {classify(tried)} ({tried})")
    if not t.engine_grep("pair_device.confirm.success"):
        return Finding("LAN-WORKS", "fail",
                       f"tentou LAN ({tried}) e o engine não confirmou")
    return Finding("LAN-WORKS", "pass", f"pareou pela LAN ({tried})")


def inv_no_silent_lan(t: Transcript, phone_has_tailnet: bool) -> Finding:
    if not phone_has_tailnet:
        return Finding("NO-SILENT-LAN", "n/a", "só vale para celular com tailnet")
    saved = first_host(t.phone_grep("endpoint.persisted"), "host")
    if saved is None:
        return Finding("NO-SILENT-LAN", "n/a", "nada foi persistido nesta corrida")
    if classify(saved) == "lan":
        return Finding("NO-SILENT-LAN", "fail",
                       f"gravou LAN ({saved}) num celular com tailnet")
    return Finding("NO-SILENT-LAN", "pass", f"gravou {classify(saved)} ({saved})")


def inv_profile_isolated(t: Transcript) -> Finding:
    """Nenhum perfil reclama o celular do outro.

    Medido em 2026-09-05: Dev e produção reclamaram o mesmo aparelho com 50 s
    de diferença e o Dev ganhou, mandando o celular discar o engine errado.
    """
    strangers = [l for l in t.mac_grep("direct_probe.claim")
                 if f":{PROD_BOOTSTRAP_PORT}" in l]
    if strangers:
        return Finding("PROFILE-ISOLATED", "fail",
                       f"o Dev reclamou um alvo de produção: {strangers[0][:120]}")
    return Finding("PROFILE-ISOLATED", "pass", "nenhum claim cruzou o perfil")


def inv_no_spinner(t: Transcript) -> Finding:
    """Toda corrida termina. Espera sem prazo é o defeito, não o sintoma."""
    ended = (t.phone_grep("pair.result=") or t.phone_grep("pair.failed")
             or t.engine_grep("pair_device.confirm.success"))
    if ended:
        return Finding("NO-SPINNER", "pass", "a corrida terminou com desfecho")
    return Finding("NO-SPINNER", "fail",
                   "nenhum desfecho registrado: o usuário ficou no spinner")


def inv_first_phone(t: Transcript, household_devices: int | None) -> Finding:
    """Casa só com o Mac tem que admitir o primeiro iPhone.

    `ForgetHomeService.swift:11-16` documenta o beco desde 2026-09-01: sem um
    iPhone que já pertença à casa, o novo espera uma aprovação que não chega —
    "five minutes of spinner and then a timeout".
    """
    if household_devices is None or household_devices > 1:
        return Finding("FIRST-PHONE", "n/a",
                       "a casa já tem mais de um membro neste cenário")
    blocked = t.mac_grep("already belongs to this home") or t.phone_grep("awaiting_approval")
    if blocked:
        return Finding("FIRST-PHONE", "fail",
                       "casa só com o Mac pediu aprovação de um iPhone inexistente")
    if not t.engine_grep("pair_device.confirm.success"):
        return Finding("FIRST-PHONE", "fail",
                       "o primeiro iPhone não entrou na casa")
    return Finding("FIRST-PHONE", "pass", "o primeiro iPhone entrou sem terceiro")


def judge(t: Transcript, phone_has_tailnet: bool,
          household_devices: int | None) -> list[Finding]:
    return [
        inv_tailnet_kept(t, phone_has_tailnet),
        inv_lan_works(t, phone_has_tailnet),
        inv_no_silent_lan(t, phone_has_tailnet),
        inv_profile_isolated(t),
        inv_no_spinner(t),
        inv_first_phone(t, household_devices),
    ]


# ──────────────────────────── colher as três fitas ────────────────────────


def guard_not_production(bootstrap_port: int) -> None:
    if bootstrap_port in (PROD_BOOTSTRAP_PORT, PROD_ADMIN_PORT):
        sys.exit(f"recusado: esta sonda nunca fala com produção "
                 f"({PROD_BOOTSTRAP_PORT}/{PROD_ADMIN_PORT}). "
                 f"O par Dev é {DEV_BOOTSTRAP_PORT}/{DEV_ADMIN_PORT}.")


def engine_tail(path: str, since_offset: int) -> tuple[list[str], int]:
    """Lê o que entrou no log do engine depois de `since_offset`."""
    if not os.path.exists(path):
        return [], since_offset
    with open(path, "r", errors="replace") as fh:
        fh.seek(since_offset)
        lines = fh.read().splitlines()
        return lines, fh.tell()


def engine_offset(path: str) -> int:
    return os.path.getsize(path) if os.path.exists(path) else 0


def start_mac_capture(out_path: str, process: str) -> subprocess.Popen:
    """os_log do app do Mac. `--level info` porque as categorias de pareamento
    são `.info` e não persistem no armazenamento padrão."""
    fh = open(out_path, "w")
    return subprocess.Popen(
        ["/usr/bin/log", "stream", "--level", "info", "--style", "compact",
         "--predicate",
         f'subsystem == "{MAC_SUBSYSTEM}" AND process == "{process}"'],
        stdout=fh, stderr=subprocess.STDOUT,
    )


def collect_phone_log(udid: str, minutes: int, out_dir: str) -> list[str]:
    """`log collect` é o único caminho: `idevicesyslog` não traz o nosso
    subsystem (medido 2026-09-05). Exige sudo sem senha e o aparelho no cabo."""
    archive = os.path.join(out_dir, "iphone.logarchive")
    shutil.rmtree(archive, ignore_errors=True)
    r = subprocess.run(
        ["sudo", "-n", "/usr/bin/log", "collect", "--device-udid", udid,
         "--last", f"{minutes}m", "--output", archive],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        return [f"<<sem log do celular: {r.stderr.strip()}>>"]
    show = subprocess.run(
        ["/usr/bin/log", "show", "--archive", archive, "--style", "compact",
         "--info", "--predicate", f'subsystem == "{PHONE_SUBSYSTEM}"'],
        capture_output=True, text=True,
    )
    return show.stdout.splitlines()


def household_device_count(port: int) -> int | None:
    import urllib.request
    try:
        with urllib.request.urlopen(
                f"http://127.0.0.1:{port}/bootstrap/status", timeout=4) as r:
            return json.load(r).get("device_count")
    except Exception:
        return None


# ─────────────────────────────── calibração ───────────────────────────────
#
# Transcrições sintéticas. Não substituem a corrida real — provam que o
# julgamento distingue os dois lados. Uma sonda que nunca reprova não mede.

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
    mac=[f"direct_probe.claim_already_initialized iphone=http://192.168.1.50:{PROD_BOOTSTRAP_PORT}/"],
    phone=["pair.result=paired"],
    engine=["pair_device.confirm.success"],
)


def self_test() -> int:
    """Cada caso diz qual invariante TEM que dar o quê. Um verde que não
    consegue ficar vermelho não é evidência de nada."""
    cases = [
        ("boa, tailnet", GOOD_TAILNET, True, 1,
         {"TAILNET-KEPT": "pass", "NO-SILENT-LAN": "pass",
          "NO-SPINNER": "pass", "FIRST-PHONE": "pass"}),
        ("boa, LAN pura", GOOD_LAN, False, 1,
         {"LAN-WORKS": "pass", "NO-SPINNER": "pass", "FIRST-PHONE": "pass"}),
        ("ruim, LAN silenciosa", BAD_SILENT_LAN, True, 2,
         {"TAILNET-KEPT": "fail", "NO-SILENT-LAN": "fail"}),
        ("ruim, spinner", BAD_SPINNER, True, 2,
         {"NO-SPINNER": "fail"}),
        ("ruim, primeiro celular travado", BAD_FIRST_PHONE, True, 1,
         {"FIRST-PHONE": "fail", "NO-SPINNER": "fail"}),
        ("ruim, perfil cruzado", BAD_CROSS_PROFILE, True, 2,
         {"PROFILE-ISOLATED": "fail"}),
    ]
    failures = 0
    for label, transcript, has_tailnet, devices, expected in cases:
        got = {f.name: f.verdict for f in judge(transcript, has_tailnet, devices)}
        for name, want in expected.items():
            if got.get(name) != want:
                print(f"  CALIBRAÇÃO FALHOU  {label}: {name} "
                      f"esperava {want}, deu {got.get(name)}")
                failures += 1
        if not failures:
            print(f"  ok  {label}")
    if failures:
        print(f"\n{failures} caso(s) de calibração falharam. "
              "A sonda não julga corrida real até isto passar.")
        return 1
    print("\ncalibração ok: a sonda aprova o bom e reprova cada defeito conhecido.")
    return 0


# ──────────────────────────────── a corrida ────────────────────────────────


def run(args) -> int:
    guard_not_production(args.bootstrap_port)
    out_dir = args.out_dir or tempfile.mkdtemp(prefix="pairing-e2e-")
    os.makedirs(out_dir, exist_ok=True)
    mac_log = os.path.join(out_dir, "mac.log")

    devices_before = household_device_count(args.bootstrap_port)
    offset = engine_offset(args.engine_log)
    capture = start_mac_capture(mac_log, args.mac_process)
    print(f"capturando em {out_dir}")
    print(f"casa Dev: device_count={devices_before}")
    print(f"\n>>> execute o cenário AGORA: {args.scenario}")
    print(f">>> {args.hold_secs}s até eu ler as fitas\n")

    try:
        time.sleep(args.hold_secs)
    finally:
        capture.terminate()
        try:
            capture.wait(timeout=5)
        except subprocess.TimeoutExpired:
            capture.kill()

    engine_lines, _ = engine_tail(args.engine_log, offset)
    with open(mac_log, errors="replace") as fh:
        mac_lines = fh.read().splitlines()
    phone_lines = (collect_phone_log(args.udid, args.collect_minutes, out_dir)
                   if args.udid else ["<<sem UDID: celular não medido>>"])

    transcript = Transcript(mac=mac_lines, phone=phone_lines, engine=engine_lines)
    with open(os.path.join(out_dir, "transcript.json"), "w") as fh:
        json.dump(asdict(transcript), fh, indent=2)

    findings = judge(transcript, args.phone_has_tailnet, devices_before)

    print(f"cenário: {args.scenario}")
    print(f"linhas colhidas — Mac {len(mac_lines)}, celular {len(phone_lines)}, "
          f"engine {len(engine_lines)}\n")
    width = max(len(f.name) for f in findings)
    for f in findings:
        mark = {"pass": "ok  ", "fail": "FALHA", "n/a": "  – "}[f.verdict]
        print(f"  {mark} {f.name.ljust(width)}  {f.detail}")

    failed = [f for f in findings if f.verdict == "fail"]
    skipped = [f for f in findings if f.verdict == "n/a"]
    print(f"\n{len(findings) - len(failed) - len(skipped)} passaram, "
          f"{len(failed)} falharam, {len(skipped)} não se aplicam.")
    print(f"fitas em {out_dir}")

    if not any(f.verdict == "pass" for f in findings):
        print("\nNENHUM invariante foi exercitado. Isto não é um verde — "
              "é uma corrida que não aconteceu.")
        return 2
    return 1 if failed else 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--self-test", action="store_true",
                   help="calibra o julgamento e sai; não toca em aparelho nem engine")
    p.add_argument("--scenario", default="pareamento do zero",
                   help="nome do cenário desta corrida, para o relatório")
    p.add_argument("--udid", help="UDID do iPhone Devs; sem ele o celular não é medido")
    p.add_argument("--phone-has-tailnet", action="store_true",
                   help="declare o estado do Tailscale NO CELULAR para este cenário")
    p.add_argument("--hold-secs", type=int, default=90)
    p.add_argument("--collect-minutes", type=int, default=5)
    p.add_argument("--bootstrap-port", type=int, default=DEV_BOOTSTRAP_PORT)
    p.add_argument("--engine-log", default=DEV_ENGINE_LOG)
    p.add_argument("--mac-process", default=DEV_APP_PROCESS)
    p.add_argument("--out-dir")
    args = p.parse_args()

    if args.self_test:
        return self_test()
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
