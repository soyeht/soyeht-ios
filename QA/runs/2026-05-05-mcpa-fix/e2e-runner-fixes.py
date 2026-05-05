#!/usr/bin/env python3
"""
E2E tests for the MCP review fixes (move_pane / close_pane / close_workspace
/ list_panes / list_workspaces / get_active_context).

E2E-08  move_pane com UUID destino inexistente  → erro, estado intacto
E2E-09  close_pane batch que esvaziaria workspace → erro, panes preservados
E2E-10  close_workspace batch que esvazia tudo   → erro, workspaces preservados
E2E-11  move_pane com colisão de handle         → response traz handle sufixado (Fix 5)
E2E-12  list_panes com UUID malformado          → erro (não cai em listar tudo)
E2E-13  list_workspaces traz isActive + activePaneID
E2E-14  list_panes traz isActive / isActiveWorkspace + activeContext
E2E-15  get_active_context retorna IDs do workspace e pane focados
E2E-16  close_pane / move_pane com handle inexistente → erro (não retorna ok vazio)
E2E-17  close_workspace batch com ID inválido/desconhecido → erro, preserva estado

Pré-requisito: SoyehtMac (Soyeht Dev) rodando, com pelo menos 1 workspace
aberto. O runner cria workspaces/worktrees temporários e tenta limpar no fim.
"""
import json, os, subprocess, time, uuid, shutil
from pathlib import Path

MCP    = "/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm-mcp-adjustments/scripts/soyeht-mcp"
IPC    = "/tmp/soyeht-qa-ipc"
REPO   = "/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm-mcp-adjustments"
WTROOT = str(Path.home() / "soyeht-worktrees" / "qa-e2e-fix")

_results = []

def call_mcp(tool, args, timeout=30.0):
    a = dict(args)
    a["automationDir"] = IPC
    a.setdefault("worktreeRoot", WTROOT)
    a.setdefault("timeout", timeout)
    init = {"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"qa-e2e-fix","version":"1"}}}
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

def expect_error(tool, args, fragment, timeout=30.0):
    """Returns (raised: bool, message: str). PASS if raised AND fragment in message."""
    try:
        r = call_mcp(tool, args, timeout=timeout)
        return False, f"expected error containing '{fragment}', got result keys={list(r.keys())[:8]}"
    except RuntimeError as e:
        msg = str(e)
        if fragment.lower() in msg.lower():
            return True, msg
        return False, f"expected '{fragment}' in error, got: {msg[:200]}"

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

def safe_close_workspace(ws_id):
    """Best-effort cleanup. Ignored if it would clear all workspaces."""
    try:
        call_mcp("close_workspace", {"workspaceIDs": [ws_id]}, timeout=10.0)
    except Exception:
        pass

# ─── E2E-08: move_pane com UUID destino inexistente ──────────────────────────
print("\n── E2E-08: move_pane destino UUID inexistente NÃO corrompe estado ──")
prune("e2e-fix-08")

try:
    fake_dest = str(uuid.uuid4())
    # Cria workspace dedicado com 1 pane (sole-pane path — o caso crítico).
    r0 = call_mcp("agent_race_panes", {
        "repo": REPO, "agents": ["shell"], "prefix": "e2e-fix-08",
        "newWorkspace": True,
    })
    panes = r0.get("createdPanes", [])
    if not panes:
        raise RuntimeError(f"setup failed: {r0}")
    src_cid = panes[0]["conversationID"]
    src_wsid = panes[0]["workspaceID"]

    # Antes do erro: confirma estado.
    before = call_mcp("list_workspaces", {})
    src_exists_before = any(w["workspaceID"] == src_wsid for w in before.get("listedWorkspaces", []))

    # Tenta mover pro UUID fake.
    raised, msg = expect_error(
        "move_pane",
        {"conversationIDs": [src_cid], "destinationWorkspaceID": fake_dest},
        "destination",
    )
    log("E2E-08a", "move_pane destino UUID fake retorna erro",
        "PASS" if raised else "FAIL", msg[:120])

    # Pós-erro: source workspace ainda existe, pane ainda lá.
    after = call_mcp("list_workspaces", {})
    src_exists_after = any(w["workspaceID"] == src_wsid for w in after.get("listedWorkspaces", []))
    pane_after = call_mcp("list_panes", {"workspaceID": src_wsid})
    pane_still_there = any(p["conversationID"] == src_cid for p in pane_after.get("listedPanes", []))

    log("E2E-08b", "Source workspace preservado após erro",
        "PASS" if (src_exists_before and src_exists_after) else "FAIL",
        f"before={src_exists_before} after={src_exists_after}")
    log("E2E-08c", "Pane fonte ainda no workspace original",
        "PASS" if pane_still_there else "FAIL",
        f"pane_still_there={pane_still_there}")

    safe_close_workspace(src_wsid)
except Exception as e:
    log("E2E-08", "move_pane destino fake", "FAIL", str(e))

# ─── E2E-09: close_pane batch que esvaziaria workspace ───────────────────────
print("\n── E2E-09: close_pane batch atômico — não destrói parcial ──────────")
prune("e2e-fix-09")

try:
    # Workspace novo com 2 panes (vai tentar fechar os 2 → deve falhar antes de qq mutation).
    r0 = call_mcp("agent_race_panes", {
        "repo": REPO, "agents": ["shell", "shell"], "prefix": "e2e-fix-09",
        "newWorkspace": True,
    })
    panes = r0.get("createdPanes", [])
    if len(panes) != 2:
        raise RuntimeError(f"setup failed, expected 2 panes got {len(panes)}: {r0}")
    cids = [p["conversationID"] for p in panes]
    ws_id = panes[0]["workspaceID"]

    raised, msg = expect_error(
        "close_pane",
        {"conversationIDs": cids},
        "empty",
    )
    log("E2E-09a", "close_pane batch inteiro retorna erro (would empty workspace)",
        "PASS" if raised else "FAIL", msg[:120])

    # Pós-erro: AMBOS os panes ainda existem.
    after = call_mcp("list_panes", {"workspaceID": ws_id})
    survivors = [p["conversationID"] for p in after.get("listedPanes", [])]
    both_alive = all(c in survivors for c in cids)
    log("E2E-09b", "Ambos panes preservados (zero mutação parcial)",
        "PASS" if both_alive else "FAIL",
        f"survivors={[s[:8] for s in survivors]} expected={[c[:8] for c in cids]}")

    safe_close_workspace(ws_id)
except Exception as e:
    log("E2E-09", "close_pane batch", "FAIL", str(e))

# ─── E2E-10: close_workspace batch que esvazia tudo ──────────────────────────
print("\n── E2E-10: close_workspace batch que tira todos → erro atômico ─────")
prune("e2e-fix-10")

try:
    # Snapshot do estado.
    before = call_mcp("list_workspaces", {})
    before_ids = [w["workspaceID"] for w in before.get("listedWorkspaces", [])]
    if not before_ids:
        raise RuntimeError("nenhum workspace para testar")

    raised, msg = expect_error(
        "close_workspace",
        {"workspaceIDs": before_ids},
        "all workspaces",
    )
    log("E2E-10a", "close_workspace batch=todos retorna erro",
        "PASS" if raised else "FAIL", msg[:120])

    after = call_mcp("list_workspaces", {})
    after_ids = [w["workspaceID"] for w in after.get("listedWorkspaces", [])]
    all_preserved = set(before_ids) == set(after_ids)
    log("E2E-10b", "Todos os workspaces preservados (zero mutação parcial)",
        "PASS" if all_preserved else "FAIL",
        f"before={len(before_ids)} after={len(after_ids)}")
except Exception as e:
    log("E2E-10", "close_workspace batch", "FAIL", str(e))

# ─── E2E-11: move_pane com colisão de handle → handle sufixado ───────────────
print("\n── E2E-11: move_pane handle collision → response traz handle final ─")
prune("e2e-fix-11")

try:
    # Workspace A com 2 panes, ambos podem ter handles default tipo @shell, @shell-2
    rA = call_mcp("agent_race_panes", {
        "repo": REPO, "agents": ["shell", "shell"], "prefix": "e2e-fix-11a",
        "newWorkspace": True,
    })
    panes_a = rA.get("createdPanes", [])
    if len(panes_a) != 2:
        raise RuntimeError(f"setup A failed: {rA}")
    ws_a = panes_a[0]["workspaceID"]

    # Workspace B com 2 panes (handles default colidem com os de A: @shell e @shell-2).
    rB = call_mcp("agent_race_panes", {
        "repo": REPO, "agents": ["shell", "shell"], "prefix": "e2e-fix-11b",
        "newWorkspace": True,
    })
    panes_b = rB.get("createdPanes", [])
    if len(panes_b) != 2:
        raise RuntimeError(f"setup B failed: {rB}")
    ws_b = panes_b[0]["workspaceID"]

    # Move 1 pane de A para B. O handle no destino vai colidir → reassignWorkspace
    # devolve um handle sufixado (-2 ou -3 dependendo do estado).
    src_pane = panes_a[0]
    src_handle_before = src_pane["handle"]
    r_move = call_mcp("move_pane", {
        "conversationIDs": [src_pane["conversationID"]],
        "destinationWorkspaceID": ws_b,
    })
    moved = r_move.get("movedPanes", [])
    if not moved:
        raise RuntimeError(f"move returned no moved panes: {r_move}")
    handle_after = moved[0]["handle"]

    # Verificação: o handle reportado precisa bater com o que está no destino agora.
    pane_state = call_mcp("list_panes", {"workspaceID": ws_b})
    actual_handles = {p["conversationID"]: p["handle"] for p in pane_state.get("listedPanes", [])}
    actual_for_moved = actual_handles.get(src_pane["conversationID"])

    consistent = (handle_after == actual_for_moved)
    log("E2E-11a", "movedPanes.handle consistente com estado real pós-move",
        "PASS" if consistent else "FAIL",
        f"reported={handle_after} actual={actual_for_moved} pre={src_handle_before}")

    safe_close_workspace(ws_a)
    safe_close_workspace(ws_b)
except Exception as e:
    log("E2E-11", "move_pane handle collision", "FAIL", str(e))

# ─── E2E-12: list_panes UUID malformado → erro ───────────────────────────────
print("\n── E2E-12: list_panes UUID malformado → erro (não lista tudo) ──────")

try:
    raised, msg = expect_error(
        "list_panes",
        {"workspaceID": "not-a-uuid-at-all"},
        "uuid",
    )
    log("E2E-12", "list_panes com UUID malformado throws",
        "PASS" if raised else "FAIL", msg[:120])
except Exception as e:
    log("E2E-12", "list_panes UUID malformado", "FAIL", str(e))

# ─── E2E-13: list_workspaces traz isActive + activePaneID ────────────────────
print("\n── E2E-13: list_workspaces traz isActive + activePaneID ────────────")

try:
    r = call_mcp("list_workspaces", {})
    workspaces = r.get("listedWorkspaces", [])
    has_isActive_field = all("isActive" in w for w in workspaces)
    actives = [w for w in workspaces if w.get("isActive")]
    has_active_pane_field = all("activePaneID" in w for w in workspaces)

    log("E2E-13a", "Todos workspaces têm campo isActive",
        "PASS" if has_isActive_field else "FAIL",
        f"workspaces={len(workspaces)}")
    log("E2E-13b", "Exatamente 1 workspace marcado como isActive=true",
        "PASS" if len(actives) == 1 else "FAIL",
        f"actives={len(actives)}")
    log("E2E-13c", "Todos workspaces expõem activePaneID (pode ser null)",
        "PASS" if has_active_pane_field else "FAIL")
except Exception as e:
    log("E2E-13", "list_workspaces active fields", "FAIL", str(e))

# ─── E2E-14: list_panes traz isActive / isActiveWorkspace + activeContext ────
print("\n── E2E-14: list_panes traz isActive/isActiveWorkspace + activeContext ")

try:
    r = call_mcp("list_panes", {})
    panes = r.get("listedPanes", [])
    ctx = r.get("activeContext")

    has_fields = all("isActive" in p and "isActiveWorkspace" in p for p in panes)
    log("E2E-14a", "Todas panes têm isActive + isActiveWorkspace",
        "PASS" if has_fields else "FAIL", f"panes={len(panes)}")

    log("E2E-14b", "Resposta inclui activeContext",
        "PASS" if ctx and ctx.get("workspaceID") else "FAIL", f"ctx={ctx}")

    # Se há panes ativos no workspace ativo, são marcados como isActive.
    actives_in_active_ws = [p for p in panes if p.get("isActive") and p.get("isActiveWorkspace")]
    log("E2E-14c", "Pelo menos 0 ou 1 pane ativo no workspace ativo (sanity)",
        "PASS" if len(actives_in_active_ws) <= 1 else "FAIL",
        f"actives_in_active_ws={len(actives_in_active_ws)}")
except Exception as e:
    log("E2E-14", "list_panes active fields", "FAIL", str(e))

# ─── E2E-15: get_active_context ──────────────────────────────────────────────
print("\n── E2E-15: get_active_context retorna workspace+pane focados ───────")

try:
    r = call_mcp("get_active_context", {})
    ctx = r.get("activeContext") or {}
    has_ws = bool(ctx.get("workspaceID"))
    has_name = "workspaceName" in ctx
    has_pane_fields = "paneID" in ctx and "paneHandle" in ctx

    log("E2E-15a", "activeContext tem workspaceID",
        "PASS" if has_ws else "FAIL", f"ctx={ctx}")
    log("E2E-15b", "activeContext tem workspaceName",
        "PASS" if has_name else "FAIL")
    log("E2E-15c", "activeContext expõe paneID/paneHandle (podem ser null)",
        "PASS" if has_pane_fields else "FAIL")

    # Cross-check: o workspaceID retornado deve ser o mesmo que list_workspaces marca como isActive.
    ws_list = call_mcp("list_workspaces", {})
    actives = [w for w in ws_list.get("listedWorkspaces", []) if w.get("isActive")]
    cross_ok = len(actives) == 1 and actives[0]["workspaceID"] == ctx.get("workspaceID")
    log("E2E-15d", "activeContext.workspaceID == list_workspaces isActive",
        "PASS" if cross_ok else "FAIL",
        f"ctx_ws={ctx.get('workspaceID', '')[:8]} list_active={(actives[0]['workspaceID'][:8] if actives else 'none')}")
except Exception as e:
    log("E2E-15", "get_active_context", "FAIL", str(e))

# ─── E2E-16: close_pane / move_pane com handle inexistente → erro ────────────
print("\n── E2E-16: close_pane handle inexistente → erro (não ok vazio) ─────")

try:
    raised, msg = expect_error(
        "close_pane",
        {"handles": ["@definitely-not-a-real-handle-xyz123"]},
        "deliver",
    )
    log("E2E-16a", "close_pane com handle inexistente throws",
        "PASS" if raised else "FAIL", msg[:120])

    raised2, msg2 = expect_error(
        "move_pane",
        {
            "handles": ["@definitely-not-a-real-handle-xyz123"],
            "destinationWorkspaceName": "x-no-such-workspace-for-fallback",
        },
        "",
    )
    # Aceita qualquer erro (UUID/handle/workspace name) — o ponto é que NÃO retorna ok vazio.
    log("E2E-16b", "move_pane com handle inexistente throws",
        "PASS" if raised2 else "FAIL", msg2[:120])
except Exception as e:
    log("E2E-16", "stale identifiers", "FAIL", str(e))

# ─── E2E-17: close_workspace batch com ID inválido/desconhecido ──────────────
print("\n── E2E-17: close_workspace valida IDs antes de fechar qualquer coisa ─")
prune("e2e-fix-17")

try:
    r0 = call_mcp("agent_race_panes", {
        "repo": REPO, "agents": ["shell"], "prefix": "e2e-fix-17",
        "newWorkspace": True,
    })
    panes = r0.get("createdPanes", [])
    if not panes:
        raise RuntimeError(f"setup failed: {r0}")
    ws_id = panes[0]["workspaceID"]

    raised, msg = expect_error(
        "close_workspace",
        {"workspaceIDs": [ws_id, "not-a-workspace-uuid"]},
        "uuid",
    )
    after_bad_format = call_mcp("list_workspaces", {})
    preserved_after_bad_format = any(
        w["workspaceID"] == ws_id
        for w in after_bad_format.get("listedWorkspaces", [])
    )
    log("E2E-17a", "ID malformado no batch retorna erro",
        "PASS" if raised else "FAIL", msg[:120])
    log("E2E-17b", "Workspace válido preservado após ID malformado",
        "PASS" if preserved_after_bad_format else "FAIL")

    fake_ws = str(uuid.uuid4())
    raised2, msg2 = expect_error(
        "close_workspace",
        {"workspaceIDs": [ws_id, fake_ws]},
        "does not exist",
    )
    after_unknown = call_mcp("list_workspaces", {})
    preserved_after_unknown = any(
        w["workspaceID"] == ws_id
        for w in after_unknown.get("listedWorkspaces", [])
    )
    log("E2E-17c", "UUID desconhecido no batch retorna erro",
        "PASS" if raised2 else "FAIL", msg2[:120])
    log("E2E-17d", "Workspace válido preservado após UUID desconhecido",
        "PASS" if preserved_after_unknown else "FAIL")

    safe_close_workspace(ws_id)
except Exception as e:
    log("E2E-17", "close_workspace invalid ids", "FAIL", str(e))

# ─── summary ─────────────────────────────────────────────────────────────────
passed = sum(1 for r in _results if r["status"]=="PASS")
failed = sum(1 for r in _results if r["status"]=="FAIL")
total  = len(_results)
print(f"\n{'='*60}")
print(f"E2E Fixes Results: {passed} PASS / {failed} FAIL  (total {total})")
if failed:
    print("\nFailed:")
    for r in _results:
        if r["status"] == "FAIL":
            print(f"  ✗ {r['id']}: {r['name']}  [{r['note']}]")
print()

raise SystemExit(0 if failed == 0 else 1)
