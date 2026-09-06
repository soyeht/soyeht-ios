#!/usr/bin/env python3
"""Exercise Swift request -> Rust HTTP/UDS/PTY -> Swift stream decoder."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def run(command, cwd, env, expected, should_fail=False):
    result = subprocess.run(command, cwd=cwd, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=900, check=False)
    if (result.returncode == 0) == should_fail or expected not in result.stdout:
        print(result.stdout)
        raise SystemExit("FAIL: command failed or the required test did not pass")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--theyos", type=Path, required=True)
    parser.add_argument("--swift-scratch", type=Path, required=True)
    args = parser.parse_args()
    swift = Path(__file__).resolve().parent.parent
    rust = args.theyos.resolve() / "admin/rust"
    required = [rust / "server-rs/src/supervised_terminals.rs",
                swift / "Packages/SoyehtCore/Tests/SoyehtCoreTests/LocalTerminalCrossRepoTests.swift"]
    if any(not path.is_file() for path in required):
        raise SystemExit("FAIL: both matching checkouts are required; skipping is not allowed")
    with tempfile.TemporaryDirectory(prefix="pty-contract-") as temporary:
        env = os.environ.copy()
        env["SOYEHT_TERMINAL_CONTRACT_DIR"] = temporary
        command = ["swift", "test", "--package-path", "Packages/SoyehtCore",
                   "--scratch-path", os.path.abspath(args.swift_scratch),
                   "--filter", "LocalTerminalCrossRepoTests/crossRepoLocalTerminal"]
        env["SOYEHT_TERMINAL_CONTRACT_STAGE"] = "encode"
        run(command, swift, env, "crossRepoLocalTerminal() passed")
        if any(not (Path(temporary) / name).is_file() for name in ("request.json", "input.json")):
            raise SystemExit("FAIL: Swift did not produce its create and keyboard requests")
        rust_command = ["cargo", "test", "-p", "server-rs", "--test", "local_terminal_metadata",
             "--jobs", "2", "supervisor_http_contract_preserves_sessions_and_fences_stale_mutations",
             "--", "--exact"]
        run(rust_command, rust, env, "1 passed; 0 failed")
        if not (Path(temporary) / "response.json").is_file():
            raise SystemExit("FAIL: Rust did not produce HTTP and WebSocket evidence")
        env["SOYEHT_TERMINAL_CONTRACT_STAGE"] = "decode"
        run(command, swift, env, "crossRepoLocalTerminal() passed")
        # Calibrate against broken boundaries in disposable exchange files.
        # Compilation failure cannot satisfy these checks: the named test
        # must have executed and failed, not merely returned a nonzero code.
        response_path = Path(temporary) / "response.json"
        original = response_path.read_text()
        for defect in ("frame_prefix", "session_instance"):
            response = json.loads(original)
            if defect == "frame_prefix":
                response["frames"][0][1] = 3
            else:
                response["created"]["session_instance_id"] = "00000000-0000-4000-8000-000000000099"
            response_path.write_text(json.dumps(response))
            run(command + ["--skip-build"], swift, env,
                "crossRepoLocalTerminal() failed", should_fail=True)
        response_path.write_text(original)
        input_path = Path(temporary) / "input.json"
        original_input = input_path.read_text()
        keyboard = json.loads(original_input)
        keyboard["type"] = "unknown_input"
        input_path.write_text(json.dumps(keyboard))
        run(rust_command, rust, env,
            "supervisor_http_contract_preserves_sessions_and_fences_stale_mutations ... FAILED",
            should_fail=True)
        input_path.write_text(original_input)
        request_path = Path(temporary) / "request.json"
        request = json.loads(request_path.read_text())
        request["wrong_intent_key"] = request.pop("intent_id")
        request_path.write_text(json.dumps(request))
        run(rust_command, rust, env,
            "supervisor_http_contract_preserves_sessions_and_fences_stale_mutations ... FAILED",
            should_fail=True)
    print("PASS: Swift create and keyboard requests executed by Rust; real HTTP/PTY frames decoded by Swift; 4 boundary defects rejected")


if __name__ == "__main__":
    main()
