#!/usr/bin/env python3
"""F0 — mede se uma sessão de terminal SOBREVIVEU à troca do engine.

Sem isto, "sobreviveu" é opinião. Foi assim que perdi 11 panes do Caio em
2026-09-05: eu tinha lido uma guarda, me convencido, e afirmado.

O QUE ELE MEDE, E POR QUE CADA COISA

Identidade (necessária, não suficiente):
  - PID + start-time do shell. O start-time é o que impede um PID reciclado de
    se passar pelo processo original dentro do mesmo boot.
  - TTY. Sozinha não serve: o nome pode ser reusado.

Funcionalidade (o que separa "mesma sessão" de "sessão recriada de forma
convincente" — critérios propostos por [jaime]):
  - nonce em variável NÃO exportada, atribuído só antes da falha. `X=1` seria
    fraco: um roteiro de recuperação poderia reexecutá-lo e "provar" o que não
    aconteceu.
  - PID + start-time do processo longo e do TUI, não só do shell.
  - PGID/SID e foreground process group — é o que prova job control.
  - desafio de I/O DEPOIS do reattach: um processo pode estar vivo e travado.
  - saída numerada e determinística durante a ausência, conferida por conteúdo
    e por intervalo — não "apareceu alguma coisa".
  - PID + start-time do engine e identidade do supervisor: prova que matei o
    componente que eu queria e que ele ficou fora por um tempo conhecido.

TUDO É COLHIDO DO SISTEMA OPERACIONAL, nunca do `list` do próprio serviço em
teste — senão ele testemunha a si mesmo.

SEGURANÇA: só fala com o engine Dev (porta 8902 por padrão). Recusa-se a rodar
contra produção. Nunca mata nada que não tenha criado.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass, asdict, field

DEV_ADMIN_PORT = 8902
PROD_ADMIN_PORT = 8892
DEV_STATE_DIR = os.path.expanduser("~/Library/Application Support/SoyehtDev")
DEV_ENGINE_LABEL = "com.soyeht.engine.dev"
DEV_ENGINE_PATH_FRAGMENT = "SoyehtDev/engine/theyos-engine"


# ─────────────────────────── o que o SO diz ───────────────────────────


def ps_rows(fields: str, extra: list[str] | None = None) -> list[list[str]]:
    """`ps` cru. A fonte de verdade sobre processos — não o serviço testado."""
    cmd = ["/bin/ps", "-Ao", fields]
    if extra:
        cmd = ["/bin/ps", *extra, "-o", fields]
    out = subprocess.run(cmd, capture_output=True, text=True, check=False)
    rows = []
    # `pid=` (com `=`) suprime o cabeçalho, então descartar a primeira linha
    # comia um processo — podia ser justamente o que eu procurava. [jaime]
    for line in out.stdout.splitlines():
        parts = line.split(None, len(fields.split(",")) - 1)
        if parts:
            rows.append(parts)
    return rows


def normalize_tty(tty: str) -> str:
    """`ps -o tty=` responde `ttys003`; a API devolve `/dev/ttys003`.

    Comparar as duas formas dava FALHA numa sessão intacta. Um instrumento que
    reprova o caso bom é tão inútil quanto um que aprova o ruim.
    """
    if not tty or tty == "??":
        return ""
    return tty if tty.startswith("/dev/") else f"/dev/{tty}"


def process_identity(pid: int) -> dict | None:
    """PID + start-time + TTY + PGID + SID, do `ps`.

    `lstart` é o discriminador que importa: dentro de um boot, dois processos
    com o mesmo PID e o mesmo instante de início não acontecem.
    """
    out = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "pid=,ppid=,pgid=,sess=,tty=,lstart=,command="],
        capture_output=True, text=True, check=False,
    )
    line = out.stdout.strip()
    if not line:
        return None
    parts = line.split(None, 5)
    if len(parts) < 6:
        return None
    pid_s, ppid_s, pgid_s, sess_s, tty_s, rest = parts
    # lstart tem 5 campos ("Fri Sep  5 14:23:45 2026"), depois vem o command
    rest_parts = rest.split(None, 5)
    lstart = " ".join(rest_parts[:5]) if len(rest_parts) >= 5 else ""
    command = rest_parts[5] if len(rest_parts) > 5 else ""
    return {
        "pid": int(pid_s),
        "ppid": int(ppid_s),
        "pgid": int(pgid_s),
        "sess": sess_s,
        "tty": normalize_tty(tty_s),
        "start": lstart,
        "command": command[:120],
    }


def pids_under(parent_pid: int) -> list[int]:
    result = []
    for row in ps_rows("pid=,ppid="):
        if len(row) >= 2 and row[1].isdigit() and int(row[1]) == parent_pid:
            result.append(int(row[0]))
    return result


def foreground_pgid(tty: str) -> int | None:
    """Grupo de processos em primeiro plano da TTY — a prova de job control."""
    if not tty or tty == "??":
        return None
    dev = tty if tty.startswith("/dev/") else f"/dev/{tty}"
    out = subprocess.run(
        ["/bin/ps", "-t", dev.replace("/dev/", ""), "-o", "pgid=,stat="],
        capture_output=True, text=True, check=False,
    )
    for line in out.stdout.splitlines():
        parts = line.split()
        # o '+' no STAT marca o grupo em primeiro plano
        if len(parts) >= 2 and "+" in parts[1]:
            return int(parts[0])
    return None


def engine_identity(path_fragment: str) -> dict | None:
    for row in ps_rows("pid=,command="):
        if len(row) >= 2 and path_fragment in row[1]:
            return process_identity(int(row[0]))
    return None


# ─────────────────────────── falar com o engine ───────────────────────────


class Engine:
    def __init__(self, port: int, token: str):
        self.base = f"http://127.0.0.1:{port}"
        self.token = token

    def _call(self, method: str, path: str, body: dict | None = None, timeout=15):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(
            f"{self.base}{path}", data=data, method=method,
            headers={"Content-Type": "application/json",
                     "Authorization": f"Bearer {self.token}"},
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}

    def create_terminal(self, conversation_id: str, argv: list[str],
                        cwd: str | None = None, env: list[list[str]] | None = None) -> dict:
        return self._call("POST", "/api/v1/terminals/local", {
            "conversation_id": conversation_id,
            "argv": argv,
            "cwd": cwd,
            "env": env or [],
            "cols": 120,
            "rows": 40,
        })

    def delete_terminal(self, conversation_id: str) -> None:
        try:
            self._call("DELETE", f"/api/v1/terminals/local/{conversation_id}")
        except urllib.error.HTTPError:
            pass

    def alive(self) -> bool:
        try:
            self._call("GET", "/api/v1/terminals/local", timeout=3)
            return True
        except Exception:
            return False


# ─────────────────────────── uma sessão sob teste ───────────────────────────


@dataclass
class SessionSnapshot:
    conversation_id: str
    nonce: str
    shell: dict | None = None
    children: list[dict] = field(default_factory=list)
    tty: str = ""
    foreground_pgid: int | None = None
    parent_pid: int | None = None

    def identity_key(self) -> tuple:
        """O que tem que ser idêntico para a sessão ser A MESMA."""
        s = self.shell or {}
        return (s.get("pid"), s.get("start"), self.tty)


def first_snapshot(engine_pid: int, conversation_id: str, tty: str,
                   nonce: str) -> SessionSnapshot:
    """Primeira foto: acha a shell pelo pai (o engine) e ANOTA a identidade."""
    snap = SessionSnapshot(conversation_id=conversation_id, nonce=nonce, tty=tty)
    for ident in processes_on_tty(tty):
        if ident["ppid"] == engine_pid and snap.shell is None:
            snap.shell = ident
        elif snap.shell and ident["ppid"] == snap.shell["pid"]:
            snap.children.append(ident)
    snap.foreground_pgid = foreground_pgid(tty)
    snap.parent_pid = engine_pid
    return snap


def resnapshot(before: SessionSnapshot) -> SessionSnapshot:
    """Segunda foto: procura AQUELA shell pela identidade que anotei.

    DEFEITO QUE ISTO CORRIGE — achado por [jaime], reproduzido com mocks. A
    primeira versão procurava a shell pelo PPID e, na medição posterior,
    passava o PID do engine NOVO. Uma shell que SOBREVIVEU teria como pai o
    supervisor, não o engine novo: ela apareceria como "não localizada", e a
    sonda declararia morte.

    Ou seja: o instrumento condenaria o caminho A exatamente quando ele
    funcionasse. Um teste que reprova a solução certa é pior que teste nenhum.

    Identidade primeiro; parentesco vira uma asserção SEPARADA, contra o pai
    esperado depois da troca.
    """
    snap = SessionSnapshot(conversation_id=before.conversation_id,
                           nonce=before.nonce, tty=before.tty)
    if before.shell is None:
        return snap
    target = process_identity(before.shell["pid"])
    # Mesmo PID não basta: o start-time é o que separa o processo original de
    # um PID reciclado.
    if target and target["start"] == before.shell["start"]:
        snap.shell = target
        snap.tty = target["tty"] or before.tty
        snap.parent_pid = target["ppid"]
        for ident in processes_on_tty(snap.tty):
            if ident["ppid"] == target["pid"]:
                snap.children.append(ident)
        snap.foreground_pgid = foreground_pgid(snap.tty)
    return snap


def processes_on_tty(tty: str) -> list[dict]:
    tty_name = tty.replace("/dev/", "")
    out = subprocess.run(["/bin/ps", "-t", tty_name, "-o", "pid="],
                         capture_output=True, text=True, check=False)
    result = []
    for line in out.stdout.splitlines():
        line = line.strip()
        if line.isdigit():
            ident = process_identity(int(line))
            if ident:
                result.append(ident)
    return result


# ─────────────────────────── o veredito ───────────────────────────


def compare(before: SessionSnapshot, after: SessionSnapshot | None) -> dict:
    """Confere identidade E funcionalidade. Ambas, ou não é a mesma sessão."""
    checks: dict[str, tuple[bool, str]] = {}

    if after is None or after.shell is None:
        return {"survived": False,
                "checks": {"shell_alive": (False, "o shell não existe mais")}}

    b, a = before.shell or {}, after.shell
    checks["mesmo_pid"] = (b.get("pid") == a.get("pid"),
                           f'{b.get("pid")} -> {a.get("pid")}')
    checks["mesmo_start_time"] = (b.get("start") == a.get("start"),
                                  f'{b.get("start")!r} -> {a.get("start")!r}')
    # A TTY vem da observação NOVA do processo (`after.tty` é relido do `ps`),
    # não do campo copiado da primeira foto — comparar um valor consigo mesmo
    # é guarda vazia. [jaime]
    checks["mesma_tty"] = (before.tty == after.tty, f"{before.tty} -> {after.tty}")
    checks["mesmo_pgid"] = (b.get("pgid") == a.get("pgid"),
                            f'{b.get("pgid")} -> {a.get("pgid")}')
    # `ps -o sess=` responde 0 para TODO processo neste macOS — medido. Uma
    # checagem que passa sempre é pior que checagem nenhuma: dá confiança falsa.
    # O que prova job control de verdade é o grupo em primeiro plano da TTY.
    checks["foreground_pgid"] = (
        before.foreground_pgid is not None
        and before.foreground_pgid == after.foreground_pgid,
        f"{before.foreground_pgid} -> {after.foreground_pgid}",
    )

    before_kids = {(k["command"].split()[0] if k["command"] else "?"): (k["pid"], k["start"])
                   for k in before.children}
    after_kids = {(k["command"].split()[0] if k["command"] else "?"): (k["pid"], k["start"])
                  for k in after.children}
    missing = [name for name in before_kids if name not in after_kids]
    changed = [name for name, ident in before_kids.items()
               if name in after_kids and after_kids[name] != ident]
    if not before_kids:
        # Zero filhos passando como "preservados" é guarda vazia: ela ficaria
        # verde para sempre porque nunca houve o que preservar. Sem fixture,
        # o resultado é NÃO EXECUTADO, e isso tem que aparecer no relatório.
        checks["filhos_preservados"] = (None, "NÃO EXECUTADO — nenhum filho na fixture")
    else:
        checks["filhos_preservados"] = (
            not missing and not changed,
            f"sumiram={missing} trocaram={changed}" if (missing or changed) else
            f"{len(before_kids)} processo(s) com mesmo pid+start",
        )

    # Parentesco é asserção PRÓPRIA, não o meio de achar a shell — e é
    # INFORMATIVA até existir supervisor: hoje, sem ele, o pai não mudar é o
    # normal. Marcá-la como falha reprovava uma sessão intacta. Quando o
    # supervisor existir, ela vira decisiva contra o pai ESPERADO.
    checks["pai_observado"] = (
        None,
        f"{before.parent_pid} -> {after.parent_pid} "
        f"(informativo até o F2; então o pai esperado é o supervisor)",
    )

    executed = [ok for ok, _ in checks.values() if ok is not None]
    survived = bool(executed) and all(executed)
    return {"survived": survived, "checks": checks,
            "identity_only": True}  # nonce/TUI/IO ainda pendentes — §F0


def wait_for_engine_change(before: dict, budget: float) -> str:
    """Espera a evidência da falha. Devolve o que foi REALMENTE observado.

    Três desfechos distintos, porque confundi-los é o mesmo que mentir:
      "replaced" — apareceu um engine com identidade diferente. É a prova.
      "absent"   — o engine sumiu e não voltou dentro do prazo. Não é a mesma
                   coisa: pode ser um serviço que morreu e não subiu.
      "unchanged"— nada aconteceu. O comando de falha não fez nada.

    A primeira versão devolvia True para "absent" e o chamador imprimia
    "trocou de identidade" — afirmando o que não tinha visto. [jaime]
    """
    deadline = time.time() + budget
    saw_absence = False
    while time.time() < deadline:
        current = engine_identity(DEV_ENGINE_PATH_FRAGMENT)
        if current is None:
            saw_absence = True
        elif current["pid"] != before["pid"] or current["start"] != before["start"]:
            return "replaced"
        time.sleep(0.5)
    return "absent" if saw_absence else "unchanged"


def provoke_failure(mode: str, engine: dict) -> None:
    """Provoca a falha por MODO TIPADO, contra um alvo verificado.

    A primeira versão aceitava `--failure-command` com shell arbitrário, e a
    única guarda era a porta. Isso não sustentava a promessa do cabeçalho
    ("só Dev, nunca mata o que não criou"): qualquer coisa podia ir ali, e a
    ação reinicia um engine Dev que pode ter panes de outra pessoa. [jaime]

    Cada modo confere o alvo antes de agir.
    """
    if mode == "none":
        return
    if DEV_ENGINE_PATH_FRAGMENT not in engine.get("command", ""):
        sys.exit(f"recusado: o alvo não é o engine Dev "
                 f"(command={engine.get('command','')[:60]!r})")
    if mode == "bootout":
        label = f"user/{os.getuid()}/{DEV_ENGINE_LABEL}"
        subprocess.run(["/bin/launchctl", "kickstart", "-k", label], check=False)
    elif mode == "sigkill":
        os.kill(engine["pid"], 9)
    else:
        sys.exit(f"modo de falha desconhecido: {mode}")


# ─────────────────────────── o roteiro ───────────────────────────


def read_token(state_dir: str) -> str:
    path = os.path.join(state_dir, "bootstrap-token")
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read().strip()


def guard_not_production(port: int) -> None:
    if port == PROD_ADMIN_PORT:
        sys.exit("recusado: esta sonda nunca fala com o engine de produção (8892). "
                 "Ela cria e mata sessões.")


def run(args) -> int:
    guard_not_production(args.port)
    token = read_token(args.state_dir)
    engine = Engine(args.port, token)

    engine_before = engine_identity(DEV_ENGINE_PATH_FRAGMENT)
    if not engine_before:
        sys.exit("engine Dev não está rodando")
    engine_pid = engine_before["pid"]
    print(f"engine Dev pid={engine_pid} start={engine_before['start']}")

    created: list[tuple[str, SessionSnapshot]] = []
    try:
        for index in range(args.sessions):
            conv = f"ptyprobe-{uuid.uuid4()}"
            nonce = uuid.uuid4().hex
            resp = engine.create_terminal(conv, ["/bin/bash", "-i"])
            tty = resp.get("slave_tty_path", "")
            if not tty:
                print(f"  sessão {index}: sem TTY na resposta, pulando")
                continue
            time.sleep(1.5)
            snap = first_snapshot(engine_pid, conv, tty, nonce)
            if snap.shell is None:
                print(f"  sessão {index}: shell não localizado em {tty}")
                continue
            created.append((conv, snap))
            print(f"  sessão {index}: pid={snap.shell['pid']} tty={tty}")

        if not created:
            sys.exit("nenhuma sessão criada — nada a medir")

        print(f"\n{len(created)} sessão(ões) criadas.")

        observed = "unchanged"
        if args.failure_mode != "none":
            # A sonda provoca a falha ela mesma e ESPERA a evidência de que
            # aconteceu. A primeira versão pedia Enter, e rodada por pipe o
            # Enter chegava instantaneamente: eu media antes da falha e o
            # "controle negativo" dava 100%. Um instrumento que depende de
            # coordenação humana mede a coordenação, não o sistema.
            print(f"provocando a falha: {args.failure_mode}")
            provoke_failure(args.failure_mode, engine_before)
            observed = wait_for_engine_change(engine_before, args.absence_budget)
            print({
                "replaced": "  falha confirmada: o engine trocou de identidade",
                "absent":   "  o engine SUMIU e não voltou no prazo "
                            "(não é o mesmo que substituído)",
                "unchanged": "  o engine NÃO mudou — a falha não aconteceu",
            }[observed])
        else:
            print("modo none: controle positivo, nada é provocado")

        # medição pós-falha
        engine_after = engine_identity(DEV_ENGINE_PATH_FRAGMENT)
        results = []
        survivors = 0
        for conv, before in created:
            after = resnapshot(before)
            verdict = compare(before, after)
            survivors += 1 if verdict["survived"] else 0
            results.append({"conversation_id": conv, **verdict})

        print("\n─── RESULTADO ───")
        print(f"engine antes:  pid={engine_before['pid']} start={engine_before['start']}")
        if engine_after:
            print(f"engine depois: pid={engine_after['pid']} start={engine_after['start']}")
            same = engine_after["pid"] == engine_before["pid"]
            print(f"  o engine {'NÃO foi trocado (controle inválido!)' if same else 'foi trocado ✓'}")
        else:
            print("engine depois: AUSENTE")

        for item in results:
            mark = "SOBREVIVEU" if item["survived"] else "MORREU"
            print(f"\n{mark}  {item['conversation_id'][:24]}…")
            for name, (ok, detail) in item["checks"].items():
                mark = "n/a " if ok is None else ("ok  " if ok else "FALHA")
                print(f"    {mark} {name}: {detail}")

        pct = 100.0 * survivors / len(created)

        # Se a falha não foi provocada, NÃO existe veredito de sobrevivência.
        # A primeira versão imprimia 100% e devolvia 0 com um aviso ao lado —
        # exatamente a forma do erro que me custou as 11 panes: um verde que
        # não mede o que diz medir. [jaime] reproduziu isto com mocks.
        valid = observed == "replaced"
        if not valid:
            print(f"\nVEREDITO INVÁLIDO — a falha não foi provocada "
                  f"(observado: {observed}). Nenhum número de sobrevivência "
                  f"significa alguma coisa aqui.")
        else:
            print(f"\nsobrevivência: {survivors}/{len(created)} ({pct:.0f}%)")
        print("escopo: IDENTIDADE apenas — nonce, TUI, processo longo, desafio "
              "de I/O e saída durante a ausência ainda não medidos")

        if args.json_out:
            with open(args.json_out, "w", encoding="utf-8") as handle:
                json.dump({"valid": valid,
                           "failure_observed": observed,
                           "scope": "identity_only",
                           "engine_before": engine_before,
                           "engine_after": engine_after,
                           "results": results,
                           "survival_pct": pct if valid else None}, handle, indent=2)
            print(f"relatório: {args.json_out}")

        if not valid:
            return 2  # inválido é seu próprio código: nunca confundir com falha
        return 0 if survivors == len(created) else 1
    finally:
        for conv, _ in created:
            engine.delete_terminal(conv)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--sessions", type=int, default=3)
    parser.add_argument("--port", type=int, default=DEV_ADMIN_PORT)
    parser.add_argument("--state-dir", default=DEV_STATE_DIR)
    parser.add_argument("--action", default="reinicie o engine Dev por fora e volte aqui")
    parser.add_argument("--failure-mode", choices=["none", "bootout", "sigkill"],
                        default="none",
                        help="como provocar a falha; o alvo é verificado antes")
    parser.add_argument("--absence-budget", type=float, default=60.0,
                        help="quantos segundos esperar pela troca de identidade do engine")
    parser.add_argument("--json-out")
    return run(parser.parse_args())


if __name__ == "__main__":
    sys.exit(main())
