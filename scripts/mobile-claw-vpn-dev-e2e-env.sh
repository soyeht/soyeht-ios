# Source-only helper for the Mobile Claw VPN DEV E2E scripts.

load_mobile_claw_vpn_dev_e2e_env() {
  local repo_root="$1"
  local explicit_env_file="${SOYEHT_MOBILE_CLAW_VPN_DEV_E2E_ENV_FILE:-}"
  local key
  local value
  local encoded_value
  local env_pairs

  env_pairs="$(
    python3 - "${repo_root}" "${explicit_env_file}" <<'PY'
import base64
import os
import sys
from pathlib import Path

repo_root = Path(sys.argv[1]).resolve()
explicit_env_file = sys.argv[2].strip()

allowed_keys = {
    "SOYEHT_RUN_MOBILE_CLAW_VPN_DEV_E2E_PREFLIGHT",
    "SOYEHT_RUN_MOBILE_CLAW_VPN_DEV_E2E",
    "SOYEHT_MOBILE_CLAW_VPN_EVIDENCE_DIR",
    "SOYEHT_MOBILE_CLAW_VPN_BUNDLE_ID",
    "SOYEHT_IOS_DEVICE_DESTINATION",
    "SOYEHT_IOS_DEVICE_ID",
    "SOYEHT_MOBILE_CLAW_VPN_DEVICE_ID",
    "SOYEHT_MOBILE_CLAW_VPN_CLAW_ID",
    "SOYEHT_MOBILE_CLAW_VPN_DEVICE_ALIAS",
    "SOYEHT_MOBILE_CLAW_VPN_CLAW_ALIAS",
    "SOYEHT_MOBILE_CLAW_VPN_RELAY_ALIAS",
    "SOYEHT_MOBILE_CLAW_VPN_MESH_ALIAS",
}


def candidate_paths() -> list[Path]:
    if explicit_env_file:
        path = Path(explicit_env_file).expanduser()
        if not path.is_absolute():
            path = repo_root / path
        return [path]
    return [
        repo_root / ".env.mobile-claw-vpn.local",
        repo_root / ".env.local",
        repo_root / ".env",
    ]


def parse_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return values

    for raw_line in lines:
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].strip()
        key, sep, value = line.partition("=")
        if not sep:
            continue
        key = key.strip()
        if key not in allowed_keys:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        if key == "SOYEHT_MOBILE_CLAW_VPN_EVIDENCE_DIR":
            value = os.path.expanduser(os.path.expandvars(value))
        values[key] = value
    return values


for candidate in candidate_paths():
    if not candidate.is_file():
        continue
    for key, value in parse_env_file(candidate).items():
        encoded = base64.b64encode(value.encode("utf-8")).decode("ascii")
        print(f"{key}\t{encoded}")
    break
PY
  )"

  while IFS=$'\t' read -r key encoded_value; do
    if [[ -z "${key}" ]]; then
      continue
    fi
    value="$(
      python3 - "${encoded_value}" <<'PY'
import base64
import sys

sys.stdout.write(base64.b64decode(sys.argv[1].encode("ascii")).decode("utf-8"))
PY
    )"
    if [[ -z "${!key+x}" ]]; then
      printf -v "${key}" '%s' "${value}"
      export "${key}"
    fi
  done <<< "${env_pairs}"
}
