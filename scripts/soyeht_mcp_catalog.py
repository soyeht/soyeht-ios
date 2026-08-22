"""Shared loader for the app-owned local agent launch catalog."""

import json
from pathlib import Path


def load_agent_catalog(caller_file):
    caller = Path(caller_file).resolve()
    candidates = [
        caller.parent / "LocalAgentCatalog.json",
        caller.parents[1] / "TerminalApp" / "SoyehtMac" / "LocalAgentCatalog.json",
    ]
    for candidate in candidates:
        try:
            document = json.loads(candidate.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if document.get("schemaVersion") != 1 or not document.get("agents"):
            continue
        agents = {
            entry["name"]: {
                "displayName": entry["displayName"],
                "executable": entry["command"],
                "modelFlag": entry["modelFlag"],
                "defaultProfile": entry.get("defaultProfile"),
            }
            for entry in document["agents"]
        }
        return agents, document.get("launchProfiles") or {}
    raise RuntimeError(
        "LocalAgentCatalog.json is missing or invalid; reinstall the Soyeht MCP integration."
    )
