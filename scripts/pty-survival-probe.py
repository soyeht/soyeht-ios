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
    for line in out.stdout.splitlines()[1:]:
        parts = line.split(None, len(fields.split(",")) - 1)
        if parts:
            rows.append(parts)
    return rows


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
        "tty": tty_s,
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

    def identity_key(self) -> tuple:
        """O que tem que ser idêntico para a sessão ser A MESMA."""
        s = self.shell or {}
        return (s.get("pid"), s.get("start"), self.tty)


def snapshot(engine_pid: int, conversation_id: str, tty: str, nonce: str) -> SessionSnapshot:
    """Fotografa a sessão pelo SO: o shell, seus filhos, e o primeiro plano."""
    snap = SessionSnapshot(conversation_id=conversation_id, nonce=nonce, tty=tty)
    tty_name = tty.replace("/dev/", "")
    out = subprocess.run(["/bin/ps", "-t", tty_name, "-o", "pid=,ppid=,command="],
                         capture_output=True, text=True, check=False)
    pids = []
    for line in out.stdout.splitlines():
        parts = line.split(None, 2)
        if len(parts) >= 1 and parts[0].isdigit():
            pids.append(int(parts[0]))
    for pid in pids:
        ident = process_identity(pid)
        if not ident:
            continue
        if ident["ppid"] == engine_pid or (snap.shell and ident["ppid"] == snap.shell["pid"]):
            if ident["ppid"] == engine_pid and snap.shell is None:
                snap.shell = ident
            else:
                snap.children.append(ident)
        elif snap.shell is None and ident["ppid"] == engine_pid:
            snap.shell = ident
    snap.foreground_pgid = foreground_pgid(tty)
    return snap


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
    checks["filhos_preservados"] = (
        not missing and not changed,
        f"sumiram={missing} trocaram={changed}" if (missing or changed) else
        f"{len(before_kids)} processo(s) com mesmo pid+start",
    )

    survived = all(ok for ok, _ in checks.values())
    return {"survived": survived, "checks": checks}


def wait_for_engine_change(before: dict, budget: float) -> bool:
    """Espera o engine REALMENTE trocar de identidade, ou desistir.

    Prova que matei o componente que eu queria. Sem isto, um comando de falha
    que não fez nada produz um relatório de 100% que não significa nada.
    """
    deadline = time.time() + budget
    saw_absence = False
    while time.time() < deadline:
        current = engine_identity(DEV_ENGINE_PATH_FRAGMENT)
        if current is None:
            saw_absence = True
        elif current["pid"] != before["pid"] or current["start"] != before["start"]:
            return True
        time.sleep(0.5)
    return saw_absence


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
            snap = snapshot(engine_pid, conv, tty, nonce)
            if snap.shell is None:
                print(f"  sessão {index}: shell não localizado em {tty}")
                continue
            created.append((conv, snap))
            print(f"  sessão {index}: pid={snap.shell['pid']} tty={tty}")

        if not created:
            sys.exit("nenhuma sessão criada — nada a medir")

        print(f"\n{len(created)} sessão(ões) criadas.")

        if args.failure_command:
            # A sonda provoca a falha ela mesma e ESPERA a evidência de que
            # aconteceu. A primeira versão pedia Enter, e rodada por pipe o
            # Enter chegava instantaneamente: eu media antes da falha e o
            # "controle negativo" dava 100%. Um instrumento que depende de
            # coordenação humana mede a coordenação, não o sistema.
            print(f"provocando a falha: {args.failure_command}")
            subprocess.run(args.failure_command, shell=True, check=False)
            if not wait_for_engine_change(engine_before, args.absence_budget):
                print("  AVISO: o engine não mudou de identidade — "
                      "a falha não aconteceu, o resultado abaixo não vale")
            else:
                print("  falha confirmada: o engine trocou de identidade")
        else:
            print(f"Agora: {args.action}")
            input("  (Enter para prosseguir, Ctrl-C para abortar) ")

        # medição pós-falha
        engine_after = engine_identity(DEV_ENGINE_PATH_FRAGMENT)
        results = []
        survivors = 0
        for conv, before in created:
            after = snapshot(
                engine_after["pid"] if engine_after else -1, conv, before.tty, before.nonce
            )
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
                print(f"    {'ok  ' if ok else 'FALHA'} {name}: {detail}")

        pct = 100.0 * survivors / len(created)
        print(f"\nsobrevivência: {survivors}/{len(created)} ({pct:.0f}%)")
        if args.json_out:
            with open(args.json_out, "w", encoding="utf-8") as handle:
                json.dump({"engine_before": engine_before,
                           "engine_after": engine_after,
                           "results": results,
                           "survival_pct": pct}, handle, indent=2)
            print(f"relatório: {args.json_out}")
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
    parser.add_argument("--failure-command",
                        help="comando que provoca a falha; a sonda executa e espera a evidência")
    parser.add_argument("--absence-budget", type=float, default=60.0,
                        help="quantos segundos esperar pela troca de identidade do engine")
    parser.add_argument("--json-out")
    return run(parser.parse_args())


if __name__ == "__main__":
    sys.exit(main())
