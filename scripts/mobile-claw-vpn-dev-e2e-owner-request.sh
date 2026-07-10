#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "${script_dir}/.." && pwd -P)"

source "${script_dir}/mobile-claw-vpn-dev-e2e-env.sh"
load_mobile_claw_vpn_dev_e2e_env "${repo_root}"

exec python3 "${script_dir}/mobile-claw-vpn-dev-e2e-owner-request.py"
