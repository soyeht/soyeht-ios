from __future__ import annotations

import os
from pathlib import Path


def _parse_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].strip()
        key, sep, value = line.partition("=")
        if not sep:
            continue
        key = key.strip()
        value = value.strip()
        if not key:
            continue
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        values[key] = value
    return values


def load_repo_env() -> Path | None:
    if os.environ.get("_SOYEHT_REPO_ENV_LOADED") == "1":
        loaded_path = os.environ.get("_SOYEHT_REPO_ENV_PATH", "")
        return Path(loaded_path) if loaded_path else None

    repo_root = Path(__file__).resolve().parents[2]
    explicit = os.environ.get("SOYEHT_ENV_FILE", "").strip()
    candidates: list[Path] = []
    if explicit:
        env_path = Path(explicit).expanduser()
        if not env_path.is_absolute():
            env_path = repo_root / env_path
        candidates.append(env_path)
    else:
        candidates.extend([repo_root / ".env.local", repo_root / ".env"])

    loaded: Path | None = None
    for path in candidates:
        if not path.is_file():
            continue
        for key, value in _parse_env_file(path).items():
            os.environ.setdefault(key, value)
        loaded = path
        break

    os.environ["_SOYEHT_REPO_ENV_LOADED"] = "1"
    if loaded is not None:
        os.environ["_SOYEHT_REPO_ENV_PATH"] = str(loaded)
    return loaded


def require_env(name: str, value: str | None = None) -> str:
    candidate = (value if value is not None else os.environ.get(name, "")).strip()
    if candidate:
        return candidate
    raise RuntimeError(f"Missing {name}. Set it in .env.local or export it in your shell.")
