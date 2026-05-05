#!/usr/bin/env -S uv run
"""
E2E tests — verifica efeitos reais, não só IPC round-trip.

send_pane_input  → shell escreve arquivo em /tmp; confirmado no filesystem
rename_panes     → resposta IPC tem renamedPanes populado
rename_workspace → resposta IPC tem renamedWorkspaces populado
arrange_panes    → resposta IPC tem arrangedPaneLayouts populado
emphasize_pane   → resposta IPC tem emphasizedPanes populado
agent_race_panes → worktrees existem no disco + panes retornados
"""
import json, os, subprocess, time, uuid, shutil
from pathlib import Path

MCP    = "/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm-mcp-adjustments/scripts/soyeht-mcp"
IPC    = "/tmp/soyeht-qa-ipc"
REPO   = "/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm-mcp-adjustments"
WTROOT = str(Path.home() / "soyeht-worktrees" / "qa-e2e")

_results = []

def call_mcp(tool, args, timeout=60.0):
    a = dict(args)
    a["automationDir"] = IPC
    a.setdefault("worktreeRoot", WTROOT)
    a.setdefault("timeout", timeout)
    init = {"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"qa-e2e","version":"1"}}}
    req  = {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":tool,"arguments":a}}
    inp  = json.dumps(init)+"\n"+json.dumps(req)+"\n"
    env  = {**os.environ,"SOYEHT_AUTOMATION_DIR":IPC}
    try:
        proc = subprocess.run([MCP], input=inp, capture_output=True, text=True, env=env, timeout=timeout+15)
    except subprocess.TimeoutExpired:
        raise RuntimeError("MCP subprocess timeout")
    for line in proc.stdout.strip().split("\n"):
        if not line.strip(): continue
        try:
            msg = json.loads(line)
            if msg.get("id") != 1: continue
            if "error" in msg: raise RuntimeError(msg["error"]["message"])
            result = msg.get("result", {})
            text   = (result.get("content") or [{}])[0].get("text", "{}")
            data   = json.loads(text)
            if result.get("isError"): raise RuntimeError(data.get("error", str(data)))
            return data
        except json.JSONDecodeError:
            pass
    raise RuntimeError(f"no response  stderr={proc.stderr[:300]}")

def log(tid, name, status, note=""):
    icon = "✓" if status=="PASS" else ("✗" if status=="FAIL" else "~")
    line = f"  {icon} {tid}: {name} — {status}" + (f"  [{note}]" if note else "")
    print(line, flush=True)
    _results.append({"id":tid,"name":name,"status":status,"note":note})

def prune(prefix):
    root = Path(WTROOT)
    if root.exists():
        for d in root.iterdir():
            if d.name.startswith(prefix):
                shutil.rmtree(d, ignore_errors=True)
    subprocess.run(["git","-C",REPO,"worktree","prune"], capture_output=True)
    r = subprocess.run(["git","-C",REPO,"branch"], capture_output=True, text=True)
    for b in r.stdout.split("\n"):
        b = b.strip().lstrip("* ")
        if b.startswith(prefix):
            subprocess.run(["git","-C",REPO,"branch","-D",b], capture_output=True)

# ─── E2E-01: send_pane_input realmente executa comando na shell ───────────────
print("\n── E2E-01: send_pane_input entrega texto + Enter e shell executa ────")

marker = f"/tmp/qa-e2e-send-{uuid.uuid4().hex[:8]}.txt"

try:
    # Abre shell pane
    r = call_mcp("open_shell", {"path": REPO, "name": "e2e-shell-send", "agent": "shell"})
    panes = r.get("createdPanes", [])
    if not panes or not panes[0].get("conversationID"):
        raise RuntimeError(f"no pane created: {r}")
    cid = panes[0]["conversationID"]
    log("E2E-01a", "open_shell retorna pane com conversationID", "PASS", f"id={cid[:16]}...")

    # Espera shell inicializar
    time.sleep(2)

    # Envia comando que cria arquivo no disco
    r2 = call_mcp("send_pane_input", {
        "conversationIDs": [cid],
        "text": f'echo "QA_E2E_SEND_OK" > {marker}',
        "lineEnding": "enter",
    })
    status_ok = r2.get("status") == "ok"
    sent = r2.get("sentPanes", [])
    log("E2E-01b", "send_pane_input retorna status ok", "PASS" if status_ok else "FAIL",
        f"sentPanes={sent}")

    # Espera shell executar
    time.sleep(3)

    # Verifica se o arquivo foi criado (prova que o Enter disparou e o comando rodou)
    if Path(marker).exists():
        content = Path(marker).read_text().strip()
        log("E2E-01c", "Comando executou — arquivo criado no disco", "PASS",
            f"content='{content}'")
    else:
        log("E2E-01c", "Comando executou — arquivo criado no disco", "FAIL",
            f"arquivo {marker} não existe — Enter não disparou ou send não chegou à pane")
except Exception as e:
    log("E2E-01", "send_pane_input E2E", "FAIL", str(e))

# ─── E2E-02: send_pane_input para múltiplas panes ─────────────────────────────
print("\n── E2E-02: send_pane_input broadcast para 3 shells ──────────────────")
markers = [f"/tmp/qa-e2e-bc-{i}-{uuid.uuid4().hex[:6]}.txt" for i in range(3)]
prune("e2e-bc")

try:
    # Abre 3 shell panes
    pane_ids = []
    for i in range(3):
        r = call_mcp("open_shell", {"path": REPO, "name": f"e2e-bc-{i}", "agent": "shell"})
        p = r.get("createdPanes", [])
        if p and p[0].get("conversationID"):
            pane_ids.append(p[0]["conversationID"])
    log("E2E-02a", f"Abriu {len(pane_ids)} shell panes", "PASS" if len(pane_ids)==3 else "FAIL",
        f"ids={[c[:8] for c in pane_ids]}")

    time.sleep(2)

    # Broadcast: cada pane recebe um comando diferente
    all_sent = True
    for i, (cid, marker) in enumerate(zip(pane_ids, markers)):
        r = call_mcp("send_pane_input", {
            "conversationIDs": [cid],
            "text": f'echo "BC_{i}" > {marker}',
            "lineEnding": "enter",
        })
        if r.get("status") != "ok":
            all_sent = False
    log("E2E-02b", "Todos os sends retornaram ok", "PASS" if all_sent else "FAIL")

    time.sleep(3)

    # Verifica cada arquivo
    hits = [Path(m).exists() for m in markers]
    log("E2E-02c", f"Comandos executaram nas 3 panes — arquivos no disco",
        "PASS" if all(hits) else "FAIL",
        f"criados={hits}")
except Exception as e:
    log("E2E-02", "broadcast E2E", "FAIL", str(e))

# ─── E2E-03: rename_panes — campo renamedPanes na resposta ───────────────────
print("\n── E2E-03: rename_panes — verifica renamedPanes na resposta IPC ─────")
prune("e2e-rename")

try:
    r0 = call_mcp("open_shell", {"path": REPO, "name": "e2e-rename-before", "agent": "shell"})
    panes = r0.get("createdPanes", [])
    cid = panes[0]["conversationID"] if panes else None
    if not cid:
        raise RuntimeError("no pane for rename test")

    r1 = call_mcp("rename_panes", {
        "conversationIDs": [cid],
        "newName": "e2e-renamed-after",
    })
    renamed = r1.get("renamedPanes", [])
    status_ok = r1.get("status") == "ok"

    if renamed:
        new_name = renamed[0].get("name") or renamed[0].get("newName") or str(renamed[0])
        log("E2E-03", "rename_panes — renamedPanes populado na resposta",
            "PASS", f"renamedPanes={renamed[0]}")
    else:
        # renamedPanes vazio mas status ok — comportamento suspeito
        log("E2E-03", "rename_panes — renamedPanes populado na resposta",
            "FAIL" if status_ok else "FAIL",
            f"status={r1.get('status')} renamedPanes=[] — rename pode ter silenciosamente falhado")
except Exception as e:
    log("E2E-03", "rename_panes E2E", "FAIL", str(e))

# ─── E2E-04: rename_workspace — campo renamedWorkspaces na resposta ──────────
print("\n── E2E-04: rename_workspace — verifica renamedWorkspaces na resposta ─")

try:
    r = call_mcp("rename_workspace", {"newName": "e2e-ws-renamed"})
    renamed = r.get("renamedWorkspaces", [])
    status_ok = r.get("status") == "ok"

    if renamed:
        log("E2E-04", "rename_workspace — renamedWorkspaces populado",
            "PASS", f"renamedWorkspaces={renamed[0]}")
    else:
        log("E2E-04", "rename_workspace — renamedWorkspaces populado",
            "FAIL",
            f"status={r.get('status')} renamedWorkspaces=[] — rename pode ter silenciosamente falhado")
except Exception as e:
    log("E2E-04", "rename_workspace E2E", "FAIL", str(e))

# ─── E2E-05: arrange_panes — arrangedPaneLayouts na resposta ─────────────────
print("\n── E2E-05: arrange_panes — verifica arrangedPaneLayouts na resposta ──")
prune("e2e-arr")

try:
    r0 = call_mcp("agent_race_panes", {"repo": REPO, "agents": ["claude","opencode","codex"], "prefix": "e2e-arr"})
    ids = [p["conversationID"] for p in r0.get("createdPanes",[]) if p.get("conversationID")]

    r1 = call_mcp("arrange_panes", {"conversationIDs": ids, "layout": "row"})
    layouts = r1.get("arrangedPaneLayouts", [])
    status_ok = r1.get("status") == "ok"

    if layouts:
        log("E2E-05", "arrange_panes — arrangedPaneLayouts populado",
            "PASS", f"layouts={layouts[0]}")
    else:
        log("E2E-05", "arrange_panes — arrangedPaneLayouts populado",
            "FAIL",
            f"status={r1.get('status')} arrangedPaneLayouts=[] — arrange pode ter silenciosamente falhado")
except Exception as e:
    log("E2E-05", "arrange_panes E2E", "FAIL", str(e))

# ─── E2E-06: emphasize_pane — emphasizedPanes na resposta ────────────────────
print("\n── E2E-06: emphasize_pane — verifica emphasizedPanes na resposta ─────")

try:
    # Usa os panes do E2E-05
    r2 = call_mcp("agent_race_panes", {"repo": REPO, "agents": ["claude"], "prefix": "e2e-emph"})
    ids2 = [p["conversationID"] for p in r2.get("createdPanes",[]) if p.get("conversationID")]

    r3 = call_mcp("emphasize_pane", {
        "conversationIDs": ids2[:1],
        "mode": "spotlight",
        "position": "right",
        "ratio": 0.7,
    })
    emphasized = r3.get("emphasizedPanes", [])
    status_ok = r3.get("status") == "ok"

    if emphasized:
        log("E2E-06", "emphasize_pane — emphasizedPanes populado",
            "PASS", f"emphasizedPanes={emphasized[0]}")
    else:
        log("E2E-06", "emphasize_pane — emphasizedPanes populado",
            "FAIL",
            f"status={r3.get('status')} emphasizedPanes=[] — spotlight pode ter silenciosamente falhado")
except Exception as e:
    log("E2E-06", "emphasize_pane E2E", "FAIL", str(e))

# ─── E2E-07: worktrees existem no disco ──────────────────────────────────────
print("\n── E2E-07: agent_race_panes — worktrees existem no disco ───────────")
prune("e2e-disk")

try:
    r = call_mcp("agent_race_panes", {
        "repo": REPO,
        "agents": ["claude","opencode","codex"],
        "prefix": "e2e-disk",
    })
    panes = r.get("createdPanes", [])
    paths = [p.get("path","") for p in panes]
    all_exist = all(Path(p).is_dir() for p in paths if p)
    git_markers = all(Path(p,".git").exists() for p in paths if p)

    log("E2E-07a", "Worktrees criados com panes retornados",
        "PASS" if len(panes)==3 else "FAIL", f"{len(panes)} panes")
    log("E2E-07b", "Dirs dos worktrees existem no disco",
        "PASS" if all_exist else "FAIL",
        f"paths_ok={[Path(p).is_dir() for p in paths]}")
    log("E2E-07c", "Cada worktree tem .git marker",
        "PASS" if git_markers else "FAIL",
        f"git_ok={[Path(p,'.git').exists() for p in paths]}")
except Exception as e:
    log("E2E-07", "worktrees no disco", "FAIL", str(e))

# ─── summary ─────────────────────────────────────────────────────────────────
passed = sum(1 for r in _results if r["status"]=="PASS")
failed = sum(1 for r in _results if r["status"]=="FAIL")
total  = len(_results)
print(f"\n{'='*60}")
print(f"E2E Results: {passed} PASS / {failed} FAIL  (total {total})")
if failed:
    print("\nFailed:")
    for r in _results:
        if r["status"] == "FAIL":
            print(f"  ✗ {r['id']}: {r['name']}  [{r['note']}]")
print()
