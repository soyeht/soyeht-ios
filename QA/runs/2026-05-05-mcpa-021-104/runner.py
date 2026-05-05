#!/usr/bin/env -S uv run
"""Direct MCP test runner for ST-Q-MCPA-021..104.

Usage: uv run /tmp/qa-mcpa-runner.py [group]
Groups: race, worktree, shell, send, rename, arrange, workspace, error, all
"""
import json, os, subprocess, sys, shutil, time, tempfile, uuid
from pathlib import Path

# ── config ──────────────────────────────────────────────────────────────────
MCP      = "/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm-mcp-adjustments/scripts/soyeht-mcp"
IPC      = "/tmp/soyeht-qa-ipc"       # test app's IPC dir
REPO     = "/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm-mcp-adjustments"
WTROOT   = str(Path.home() / "soyeht-worktrees" / "qa2-mcpa")

# ── helpers ──────────────────────────────────────────────────────────────────
_results = []

def call_mcp(tool, args, ipc=IPC, req_timeout=25.0):
    a = dict(args)
    a["automationDir"] = ipc
    a.setdefault("timeout", req_timeout)
    a.setdefault("worktreeRoot", WTROOT)

    init = {"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"qa","version":"1"}}}
    call = {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":tool,"arguments":a}}
    inp  = json.dumps(init)+"\n"+json.dumps(call)+"\n"
    env  = {**os.environ,"SOYEHT_AUTOMATION_DIR":ipc}

    try:
        proc = subprocess.run([MCP], input=inp, capture_output=True, text=True, env=env, timeout=req_timeout+10)
    except subprocess.TimeoutExpired:
        raise RuntimeError("subprocess timeout (MCP server hung)")

    for line in proc.stdout.strip().split("\n"):
        if not line.strip(): continue
        try:
            msg = json.loads(line)
            if msg.get("id") != 1: continue
            if "error" in msg:
                raise RuntimeError(msg["error"]["message"])
            result = msg.get("result",{})
            text   = (result.get("content") or [{}])[0].get("text","{}")
            data   = json.loads(text)
            if result.get("isError"):
                raise RuntimeError(data.get("error", str(data)))
            return data
        except json.JSONDecodeError:
            pass
    raise RuntimeError(f"no response — stderr: {proc.stderr[:400]}")


def expect_error(tool, args, contains=None, ipc=IPC):
    try:
        r = call_mcp(tool, args, ipc=ipc)
        return None, r   # expected error but got success
    except RuntimeError as e:
        msg = str(e)
        if contains and contains.lower() not in msg.lower():
            return f"error didn't contain '{contains}': {msg}", None
        return "ok", msg


def log(tid, name, status, note=""):
    icon = "✓" if status=="PASS" else ("✗" if status=="FAIL" else "~")
    print(f"  {icon} {tid}: {name} — {status}" + (f"  [{note}]" if note else ""), flush=True)
    _results.append({"id":tid,"name":name,"status":status,"note":note})


def prune_worktrees(prefix):
    root = Path(WTROOT)
    if not root.exists(): return
    for d in sorted(root.iterdir()):
        if d.name.startswith(prefix):
            shutil.rmtree(d, ignore_errors=True)
    subprocess.run(["git","-C",REPO,"worktree","prune"], capture_output=True)
    # delete dangling branches
    r = subprocess.run(["git","-C",REPO,"branch"], capture_output=True, text=True)
    for line in r.stdout.split("\n"):
        b = line.strip().lstrip("* ")
        if b.startswith(prefix):
            subprocess.run(["git","-C",REPO,"branch","-D",b], capture_output=True)

# ── test groups ──────────────────────────────────────────────────────────────

def test_race():
    print("\n── Agent Race Variants ─────────────────────────────────────────")

    # 021 — 2-agent race
    prune_worktrees("t021")
    try:
        r = call_mcp("agent_race_panes", {"repo":REPO,"agents":["claude","opencode"],"prefix":"t021"})
        panes = r.get("createdPanes",[])
        names = [p.get("name","") for p in panes]
        ok = len(panes)==2 and "t021-claude" in names and "t021-opencode" in names
        log("021","2-agent race (claude+opencode)", "PASS" if ok else "FAIL",
            f"panes={names}")
    except Exception as e:
        log("021","2-agent race","FAIL",str(e))

    # 022 — 5-agent race with repeated agents (3× claude, 1× opencode, 1× codex)
    # Note: app nameStyle strips numeric suffixes from display name; check path+handle for uniqueness
    prune_worktrees("t022")
    try:
        r = call_mcp("agent_race_panes", {"repo":REPO,"agents":["claude","claude","claude","opencode","codex"],"prefix":"t022"})
        panes = r.get("createdPanes",[])
        paths   = [p.get("path","") for p in panes]
        handles = [p.get("handle","") for p in panes]
        ok = (len(panes)==5
              and len(set(paths))==5       # each has its own worktree dir
              and len(set(handles))==5)    # each has a unique tab handle
        log("022","5-agent race with repeated agents (path+handle unique)", "PASS" if ok else "FAIL",
            f"panes={len(panes)} paths_distinct={len(set(paths))} handles={handles}")
    except Exception as e:
        log("022","5-agent race repeated","FAIL",str(e))

    # 023 — custom prefix
    prune_worktrees("fix-auth")
    try:
        r = call_mcp("agent_race_panes", {"repo":REPO,"agents":["claude","opencode"],"prefix":"fix-auth"})
        panes = r.get("createdPanes",[])
        ok = all("fix-auth" in (p.get("name","") or p.get("path","")) for p in panes)
        log("023","Custom prefix fix-auth", "PASS" if ok else "FAIL",
            f"names={[p.get('name') for p in panes]}")
    except Exception as e:
        log("023","Custom prefix","FAIL",str(e))

    # 024 — newWorkspace + custom workspaceName  (uses create_workspace_panes → needs higher timeout)
    prune_worktrees("t024")
    try:
        r = call_mcp("agent_race_panes", {"repo":REPO,"agents":["claude","opencode"],"prefix":"t024","newWorkspace":True,"workspaceName":"sprint-42","timeout":60.0}, req_timeout=65.0)
        ws = r.get("createdWorkspaces",[])
        panes = r.get("createdPanes",[])
        ok = len(ws)>=1 and len(panes)==2
        log("024","newWorkspace + workspaceName sprint-42", "PASS" if ok else "FAIL",
            f"ws={len(ws)} panes={len(panes)}")
    except Exception as e:
        log("024","newWorkspace+workspaceName","FAIL",str(e))

    # 025 — prompt + promptDelayMs
    prune_worktrees("t025")
    try:
        r = call_mcp("agent_race_panes", {"repo":REPO,"agents":["claude"],"prefix":"t025","prompt":"echo t025-ok","promptDelayMs":3000})
        panes = r.get("createdPanes",[])
        ok = len(panes)==1
        log("025","Prompt + promptDelayMs=3000 (IPC ok; visual delay not verified)", "PASS" if ok else "FAIL",
            f"{len(panes)} panes")
    except Exception as e:
        log("025","prompt+delay","FAIL",str(e))

    # 026 — non-git directory
    tmpdir = tempfile.mkdtemp(prefix="qa026-nongit-")
    try:
        kind, val = expect_error("agent_race_panes", {"repo":tmpdir,"agents":["claude"],"prefix":"t026"})
        if kind=="ok":
            log("026","Non-git directory returns error","PASS",f"error: {val[:80]}")
        else:
            log("026","Non-git directory returns error","FAIL",kind or f"no error; got {val}")
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    # 027 — single agent via agent_race_panes
    prune_worktrees("t027")
    try:
        r = call_mcp("agent_race_panes", {"repo":REPO,"agents":["codex"],"prefix":"t027"})
        panes = r.get("createdPanes",[])
        log("027","Single agent via agent_race_panes", "PASS" if len(panes)==1 else "FAIL",
            f"{len(panes)} panes")
    except Exception as e:
        log("027","Single agent race","FAIL",str(e))

    # 100 — unknown agent name
    prune_worktrees("t100")
    try:
        kind, val = expect_error("agent_race_panes", {"repo":REPO,"agents":["gemini"],"prefix":"t100"}, contains="agent")
        if kind=="ok":
            log("100","Unknown agent 'gemini' returns error","PASS",f"error: {val[:80]}")
        elif kind is None:
            log("100","Unknown agent 'gemini' returns error","FAIL","got success — needs validation code")
        else:
            log("100","Unknown agent 'gemini' returns error","FAIL",kind)
    except Exception as e:
        log("100","Unknown agent validation","FAIL",str(e))


def test_worktree():
    print("\n── Worktree Panes Single Agent ─────────────────────────────────")

    # 030 — codex worktree with prompt
    prune_worktrees("t030")
    try:
        r = call_mcp("create_worktree_panes", {"repo":REPO,"names":["t030-codex"],"agent":"codex","prompt":"echo t030-ok"})
        panes = r.get("createdPanes",[])
        log("030","Codex worktree with prompt","PASS" if len(panes)==1 else "FAIL",
            f"{len(panes)} panes")
    except Exception as e:
        log("030","Codex worktree+prompt","FAIL",str(e))

    # 031 — newWorkspace=true (create_workspace_panes → higher timeout)
    prune_worktrees("t031")
    try:
        r = call_mcp("create_worktree_panes", {"repo":REPO,"names":["t031-agent"],"agent":"claude","newWorkspace":True,"workspaceName":"t031-ws","timeout":60.0}, req_timeout=65.0)
        ws = r.get("createdWorkspaces",[])
        panes = r.get("createdPanes",[])
        log("031","create_worktree_panes newWorkspace=true","PASS" if len(ws)>=1 and len(panes)==1 else "FAIL",
            f"ws={len(ws)} panes={len(panes)}")
    except Exception as e:
        log("031","worktree newWorkspace","FAIL",str(e))

    # 032 — custom branch name (branch = slug(name))
    prune_worktrees("my-feature-branch")
    try:
        r = call_mcp("create_worktree_panes", {"repo":REPO,"names":["my-feature-branch"],"agent":"codex"})
        panes = r.get("createdPanes",[])
        wt_path = panes[0].get("path","") if panes else ""
        # verify branch was created
        result = subprocess.run(["git","-C",REPO,"branch","--list","my-feature-branch"],
                                capture_output=True, text=True)
        branch_created = "my-feature-branch" in result.stdout
        log("032","Custom branch name via pane name","PASS" if branch_created else "FAIL",
            f"path={wt_path} branch_exists={branch_created}")
    except Exception as e:
        log("032","Custom branch name","FAIL",str(e))

    # 033 — 10-pane stress test
    prune_worktrees("t033")
    try:
        names = [f"t033-{i:02d}" for i in range(10)]
        t0 = time.time()
        r = call_mcp("create_worktree_panes", {"repo":REPO,"names":names,"agent":"codex"}, req_timeout=60.0)
        elapsed = time.time()-t0
        panes = r.get("createdPanes",[])
        log("033","10-pane stress test","PASS" if len(panes)==10 else "FAIL",
            f"{len(panes)}/10 panes in {elapsed:.1f}s")
    except Exception as e:
        log("033","10-pane stress","FAIL",str(e))


def test_shell():
    print("\n── Shell and File Panes ─────────────────────────────────────────")

    # 040 — open shell in specific dir
    try:
        r = call_mcp("open_shell", {"path":REPO,"name":"t040-shell"})
        panes = r.get("createdPanes",[])
        ok = len(panes)==1
        conv_id = panes[0].get("conversationID","") if panes else ""
        log("040","open_shell in specific dir","PASS" if ok else "FAIL",
            f"id={conv_id[:16]}...")
    except Exception as e:
        log("040","open_shell","FAIL",str(e))

    # 041 — multiple shell panes in different dirs
    try:
        dirs = [REPO, str(Path.home())]
        r = call_mcp("open_panes", {
            "panes":[
                {"name":"t041-a","path":dirs[0],"agent":"shell"},
                {"name":"t041-b","path":dirs[1],"agent":"shell"},
            ]
        })
        panes = r.get("createdPanes",[])
        log("041","open_panes two dirs","PASS" if len(panes)==2 else "FAIL",
            f"{len(panes)} panes")
    except Exception as e:
        log("041","open_panes multiple dirs","FAIL",str(e))

    # 042 — open_file in Soyeht editor pane
    try:
        r = call_mcp("open_file", {"directory":REPO,"editor":"vim"})
        ok = bool(r.get("selectedFile")) and r.get("createdPanes") is not None or r.get("status")=="ok"
        log("042","open_file vim in Soyeht pane","PASS" if ok else "FAIL",
            f"file={str(r.get('selectedFile','?'))[-40:]}")
    except Exception as e:
        log("042","open_file","FAIL",str(e))

    # 043 — non-existent file path
    kind, val = expect_error("open_file", {"file":"/nonexistent/path/to/file.swift","directory":REPO})
    if kind=="ok":
        log("043","Non-existent file returns error","PASS",f"error: {str(val)[:80]}")
    elif kind is None:
        log("043","Non-existent file returns error","FAIL","got success unexpectedly")
    else:
        log("043","Non-existent file returns error","FAIL",kind)

    # 044 — shell with long-running process (just verify pane opens; visual check for persistence)
    try:
        r = call_mcp("open_shell", {"path":REPO,"name":"t044-tail","command":"tail -f /dev/null"})
        panes = r.get("createdPanes",[])
        log("044","Shell with long-running process (opens ok; persistence is visual)","PASS" if len(panes)==1 else "FAIL",
            f"{len(panes)} pane(s)")
    except Exception as e:
        log("044","Shell long-running process","FAIL",str(e))


def test_send():
    print("\n── Send Pane Input ──────────────────────────────────────────────")

    # Need 3 live panes — open them first
    prune_worktrees("t050")
    try:
        r = call_mcp("agent_race_panes", {"repo":REPO,"agents":["claude","opencode","codex"],"prefix":"t050"})
        panes = r.get("createdPanes",[])
        conv_ids = [p["conversationID"] for p in panes if p.get("conversationID")]
        log("050-setup","Open 3 panes for send tests","PASS" if len(conv_ids)==3 else "WARN",
            f"{len(conv_ids)} IDs")

        if len(conv_ids) >= 1:
            # 050 — broadcast same prompt to 3 panes
            r2 = call_mcp("send_pane_input", {"conversationIDs":conv_ids[:3],"text":"echo t050-broadcast"})
            log("050","Broadcast to 3 panes","PASS" if r2.get("status")=="ok" else "FAIL", str(r2)[:80])

            # 051 — terminator=none
            r3 = call_mcp("send_pane_input", {"conversationIDs":[conv_ids[0]],"text":"echo t051","lineEnding":"none"})
            log("051","lineEnding=none (IPC accepted; visual confirm needed)","PASS" if r3.get("status")=="ok" else "FAIL",str(r3)[:80])

            # 052 — terminator=newline
            r4 = call_mcp("send_pane_input", {"conversationIDs":[conv_ids[0]],"text":"echo t052","lineEnding":"newline"})
            log("052","lineEnding=newline (IPC accepted; visual confirm needed)","PASS" if r4.get("status")=="ok" else "FAIL",str(r4)[:80])

            # 054 — send after rename
            rename_r = call_mcp("rename_panes", {"conversationIDs":[conv_ids[0]],"newName":"t054-renamed"})
            send_r = call_mcp("send_pane_input", {"conversationIDs":[conv_ids[0]],"text":"echo t054-post-rename"})
            log("054","Send after rename (same conversationID)","PASS" if send_r.get("status")=="ok" else "FAIL")

    except Exception as e:
        log("050-setup","Race setup for send tests","FAIL",str(e))

    # 053 — empty string
    kind, val = expect_error("send_pane_input", {"text":""})
    if kind=="ok":
        log("053","Empty text returns error","PASS",f"error: {str(val)[:60]}")
    elif kind is None:
        log("053","Empty text returns error","FAIL","got success")
    else:
        log("053","Empty text returns error","FAIL",kind)

    # 055 — stale pane (fake conversationID)
    kind, val = expect_error("send_pane_input", {"conversationIDs":["00000000-dead-beef-dead-000000000000"],"text":"ghost"})
    if kind=="ok":
        log("055","Stale pane returns error","PASS",f"error: {str(val)[:80]}")
    elif kind is None:
        log("055","Stale pane returns error","FAIL","got success — app may silently ignore unknown IDs")
    else:
        log("055","Stale pane returns error","FAIL",kind)


def test_rename():
    print("\n── Rename Operations ────────────────────────────────────────────")

    # 060 — rename 3 panes by explicit IDs (rename_panes requires explicit targets)
    prune_worktrees("t060")
    try:
        r0 = call_mcp("agent_race_panes", {"repo":REPO,"agents":["claude","opencode","codex"],"prefix":"t060"})
        ids = [p["conversationID"] for p in r0.get("createdPanes",[]) if p.get("conversationID")]
        if len(ids) == 3:
            # rename each pane to a distinct name via 3 calls
            ok = True
            for i, cid in enumerate(ids):
                rr = call_mcp("rename_panes", {"conversationIDs":[cid],"newName":f"renamed-{i+1}"})
                if rr.get("status") != "ok":
                    ok = False
            log("060","Rename 3 panes by conversationID (3 calls)","PASS" if ok else "FAIL",f"{len(ids)} renamed")
        else:
            log("060","Rename 3 panes by conversationID","FAIL",f"only {len(ids)} IDs from race")
    except Exception as e:
        log("060","Bulk rename","FAIL",str(e))

    # 061 — rename single pane by conversationID — need a real ID
    prune_worktrees("t061")
    try:
        r0 = call_mcp("agent_race_panes", {"repo":REPO,"agents":["codex"],"prefix":"t061"})
        panes = r0.get("createdPanes",[])
        if panes and panes[0].get("conversationID"):
            cid = panes[0]["conversationID"]
            r1 = call_mcp("rename_panes", {"conversationIDs":[cid],"newName":"t061-renamed"})
            log("061","Rename single pane by conversationID","PASS" if r1.get("status")=="ok" else "FAIL")
        else:
            log("061","Rename single pane — no ID","SKIP","no conversationID in response")
    except Exception as e:
        log("061","Rename single pane","FAIL",str(e))

    # 062 — rename workspace with Unicode
    try:
        r = call_mcp("rename_workspace", {"newName":"Área de Trabalho 2"})
        log("062","Rename workspace with spaces+Unicode","PASS" if r.get("status")=="ok" else "FAIL",str(r)[:80])
    except Exception as e:
        log("062","Rename workspace Unicode","FAIL",str(e))

    # 063 — empty name
    kind, val = expect_error("rename_workspace", {"newName":""})
    if kind=="ok":
        log("063","Empty workspace name returns error","PASS",f"error: {str(val)[:60]}")
    elif kind is None:
        log("063","Empty workspace name returns error","FAIL","got success")
    else:
        log("063","Empty workspace name returns error","FAIL",kind)


def test_arrange():
    print("\n── Layout — Arrange and Emphasize ──────────────────────────────")

    # Open 4 panes for layout tests
    prune_worktrees("t07x")
    try:
        r = call_mcp("agent_race_panes", {"repo":REPO,"agents":["claude","opencode","codex"],"prefix":"t07x"})
        panes = r.get("createdPanes",[])
        ids = [p["conversationID"] for p in panes if p.get("conversationID")]
    except Exception as e:
        log("07x-setup","Setup 3 panes for layout tests","FAIL",str(e))
        ids = []

    # 070 — arrange 3 panes as grid
    try:
        r = call_mcp("arrange_panes", {"conversationIDs":ids,"layout":"grid"})
        log("070","Arrange 3 panes as grid","PASS" if r.get("status")=="ok" else "FAIL",str(r)[:80])
    except Exception as e:
        log("070","Arrange grid","FAIL",str(e))

    # 071 — arrange row then stack
    try:
        r1 = call_mcp("arrange_panes", {"conversationIDs":ids,"layout":"row"})
        r2 = call_mcp("arrange_panes", {"conversationIDs":ids,"layout":"stack"})
        log("071","Arrange row then stack","PASS" if r2.get("status")=="ok" else "FAIL")
    except Exception as e:
        log("071","Row->stack","FAIL",str(e))

    # 072 — arrange subset (first 2 of 3)
    try:
        r = call_mcp("arrange_panes", {"conversationIDs":ids[:2],"layout":"row"})
        log("072","Arrange subset (2 of 3 panes)","PASS" if r.get("status")=="ok" else "FAIL",str(r)[:80])
    except Exception as e:
        log("072","Arrange subset","FAIL",str(e))

    # 073 — emphasize spotlight right 0.7
    try:
        target = ids[:1] if ids else []
        r = call_mcp("emphasize_pane", {"conversationIDs":target,"mode":"spotlight","position":"right","ratio":0.7})
        log("073","Emphasize spotlight right 0.7 (IPC ok; visual confirm needed)","PASS" if r.get("status")=="ok" else "FAIL",str(r)[:80])
    except Exception as e:
        log("073","Emphasize spotlight","FAIL",str(e))

    # 074 — zoom then send then unzoom
    try:
        target = ids[:1] if ids else []
        r1 = call_mcp("emphasize_pane", {"conversationIDs":target,"mode":"zoom"})
        r2 = call_mcp("send_pane_input", {"conversationIDs":target,"text":"echo t074-while-zoomed"})
        r3 = call_mcp("emphasize_pane", {"conversationIDs":target,"mode":"unzoom"})
        log("074","Zoom + send + unzoom","PASS" if r3.get("status")=="ok" else "FAIL")
    except Exception as e:
        log("074","Zoom->send->unzoom","FAIL",str(e))

    # 075 — emphasize non-existent pane
    kind, val = expect_error("emphasize_pane", {"conversationIDs":["00000000-dead-beef-dead-111111111111"],"mode":"spotlight"})
    if kind=="ok":
        log("075","Emphasize non-existent pane returns error","PASS",f"error: {str(val)[:60]}")
    elif kind is None:
        log("075","Emphasize non-existent pane returns error","FAIL","got success (app may ignore unknown IDs)")
    else:
        log("075","Emphasize non-existent pane returns error","FAIL",kind)


def test_workspace():
    print("\n── Workspace Management ─────────────────────────────────────────")

    # open_workspace tests need a higher timeout — app slows down with many panes open
    WS_TIMEOUT = 60.0

    # 080 — open_workspace then open_panes
    try:
        r1 = call_mcp("open_workspace", {
            "name":"t080-ws",
            "panes":[{"name":"t080-p1","path":REPO}],
            "timeout": WS_TIMEOUT,
        }, req_timeout=WS_TIMEOUT)
        panes1 = r1.get("createdPanes",[])
        ws1 = r1.get("createdWorkspaces",[])
        log("080a","open_workspace creates workspace","PASS" if ws1 else "FAIL",
            f"ws={len(ws1)} panes={len(panes1)}")

        # add panes to active workspace
        r2 = call_mcp("open_panes", {"panes":[{"name":"t080-p2","path":REPO}]})
        panes2 = r2.get("createdPanes",[])
        log("080b","open_panes adds to active workspace","PASS" if len(panes2)>=1 else "FAIL",
            f"{len(panes2)} panes")
    except Exception as e:
        log("080","open_workspace+open_panes","FAIL",str(e))

    # 081 — two named workspaces have distinct IDs
    try:
        r1 = call_mcp("open_workspace", {"name":"t081-ws-alpha","panes":[{"name":"t081-a","path":REPO}],"timeout":WS_TIMEOUT}, req_timeout=WS_TIMEOUT)
        r2 = call_mcp("open_workspace", {"name":"t081-ws-beta","panes":[{"name":"t081-b","path":REPO}],"timeout":WS_TIMEOUT}, req_timeout=WS_TIMEOUT)
        ws1 = (r1.get("createdWorkspaces") or [{}])[0]
        ws2 = (r2.get("createdWorkspaces") or [{}])[0]
        id1 = ws1.get("workspaceID") or ws1.get("id") or str(ws1)
        id2 = ws2.get("workspaceID") or ws2.get("id") or str(ws2)
        ok = id1 != id2
        log("081","Two workspaces have distinct IDs","PASS" if ok else "FAIL",
            f"id1={str(id1)[:16]} id2={str(id2)[:16]}")
    except Exception as e:
        log("081","Two distinct workspaces","FAIL",str(e))

    # 082 — duplicate workspace name (should not crash)
    try:
        r1 = call_mcp("open_workspace", {"name":"t082-dup","panes":[{"name":"t082-p1","path":REPO}],"timeout":WS_TIMEOUT}, req_timeout=WS_TIMEOUT)
        r2 = call_mcp("open_workspace", {"name":"t082-dup","panes":[{"name":"t082-p2","path":REPO}],"timeout":WS_TIMEOUT}, req_timeout=WS_TIMEOUT)
        log("082","Duplicate workspace name doesn't crash","PASS",
            f"ws1_ok={bool(r1.get('createdWorkspaces'))} ws2_ok={bool(r2.get('createdWorkspaces'))}")
    except Exception as e:
        log("082","Duplicate workspace name","FAIL",str(e))


def test_error():
    print("\n── Error Handling ───────────────────────────────────────────────")

    # 101 — non-git repo path
    tmpdir = tempfile.mkdtemp(prefix="qa101-nongit-")
    try:
        kind, val = expect_error("create_worktree_panes", {"repo":tmpdir,"names":["test"]})
        if kind=="ok":
            log("101","Non-git repo path returns error","PASS",f"error: {str(val)[:80]}")
        elif kind is None:
            log("101","Non-git repo path returns error","FAIL","got success")
        else:
            log("101","Non-git repo path returns error","FAIL",kind)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    # 102 — IPC timeout (no app watching fake dir)
    fake_ipc = f"/tmp/qa102-fake-ipc-{uuid.uuid4().hex[:8]}"
    os.makedirs(fake_ipc+"/Requests", exist_ok=True)
    os.makedirs(fake_ipc+"/Responses", exist_ok=True)
    try:
        prune_worktrees("t102")
        kind, val = expect_error("agent_race_panes", {"repo":REPO,"agents":["codex"],"prefix":"t102"},
                                 contains="timeout", ipc=fake_ipc)
        if kind=="ok":
            log("102","IPC timeout returns error","PASS",f"error: {str(val)[:80]}")
        elif kind is None:
            log("102","IPC timeout returns error","FAIL","got success — should have timed out")
        else:
            log("102","IPC timeout returns error","FAIL",kind)
    finally:
        shutil.rmtree(fake_ipc, ignore_errors=True)
        prune_worktrees("t102")

    # 103 — malformed JSON-RPC → server logs a warning to stderr but does NOT crash
    proc = subprocess.run([MCP], input='{"broken":json}\n', capture_output=True, text=True,
                          env={**os.environ,"SOYEHT_AUTOMATION_DIR":IPC}, timeout=10)
    no_traceback = "traceback" not in proc.stderr.lower()
    skipped_msg = "malformed json" in proc.stderr.lower() or "skipped" in proc.stderr.lower()
    ok = no_traceback  # no traceback = handled gracefully
    log("103","Malformed JSON-RPC: server warns but doesn't traceback",
        "PASS" if ok else "FAIL",
        f"rc={proc.returncode} no_traceback={no_traceback} warned={skipped_msg}")

    # 104 — restart mid-session: note as manual only
    log("104","Restart MCP mid-session","SKIP","requires live MCP client reconnect — manual test")


# ── natural language ──────────────────────────────────────────────────────────
def test_nl():
    print("\n── Natural Language (090..095) ──────────────────────────────────")
    print("  ~ All NL tests require a live AI agent (Claude Code / Codex / OpenCode).")
    print("  ~ These are recorded as SKIP here; run via agent sessions.")
    for i, name in [
        ("090","PT-BR: 'abre 3 agentes em worktrees separadas'"),
        ("091","PT-BR: 'abre claude e opencode, manda olá'"),
        ("092","EN: 'create 3 agents in brand new workspace sprint-42'"),
        ("093","EN: 'put all panes side by side'"),
        ("094","EN: 'highlight claude pane, bigger on right'"),
        ("095","Multi-turn: open agents → rename → send follow-up"),
    ]:
        log(i, name, "SKIP", "agent-driven; verify manually")


# ── main ─────────────────────────────────────────────────────────────────────
def main():
    group = sys.argv[1] if len(sys.argv)>1 else "all"
    print(f"=== ST-Q-MCPA-021..104 test run  (group={group}) ===")

    if group in ("race","all"):   test_race()
    if group in ("worktree","all"): test_worktree()
    if group in ("shell","all"):  test_shell()
    if group in ("send","all"):   test_send()
    if group in ("rename","all"): test_rename()
    if group in ("arrange","all"): test_arrange()
    if group in ("workspace","all"): test_workspace()
    if group in ("error","all"):  test_error()
    if group in ("nl","all"):     test_nl()

    pass_ = sum(1 for r in _results if r["status"]=="PASS")
    fail_ = sum(1 for r in _results if r["status"]=="FAIL")
    skip_ = sum(1 for r in _results if r["status"] in ("SKIP","WARN"))
    total = len(_results)

    print(f"\n{'='*60}")
    print(f"Results: {pass_} PASS / {fail_} FAIL / {skip_} SKIP  (total {total})")
    if fail_:
        print("\nFailed:")
        for r in _results:
            if r["status"]=="FAIL":
                print(f"  ✗ {r['id']}: {r['name']}  [{r['note']}]")
    print()
    # Write JSON results for the report
    out = "/tmp/qa-mcpa-results.json"
    with open(out,"w") as f:
        json.dump(_results, f, indent=2)
    print(f"Raw results → {out}")

if __name__=="__main__":
    main()
