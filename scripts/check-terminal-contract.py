#!/usr/bin/env python3
"""Exercise Swift request -> Rust HTTP/UDS/PTY -> Swift stream decoder."""
import argparse
import json
import os
import signal
from pathlib import Path
import subprocess
import tempfile
import time


def run(command, cwd, env, expected, should_fail=False):
    result = subprocess.run(command, cwd=cwd, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=900, check=False)
    if (result.returncode == 0) == should_fail or expected not in result.stdout:
        print(result.stdout)
        raise SystemExit("FAIL: command failed or the required test did not pass")


def rust_exchange(command, rust, swift_command, swift, env, directory, defect=None):
    for name in ("issued.json", "request.json", "request-ready.json", "input.json", "response.json"):
        (directory / name).unlink(missing_ok=True)
    with tempfile.TemporaryFile(mode="w+") as output:
        process = subprocess.Popen(command, cwd=rust, env=env, text=True,
                                   stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            deadline = time.monotonic() + 900
            while not (directory / "issued.json").is_file():
                if process.poll() is not None or time.monotonic() > deadline:
                    output.seek(0)
                    print(output.read())
                    raise SystemExit("FAIL: Rust did not issue a real ticket")
                time.sleep(0.02)
            encode_env = dict(env, SOYEHT_TERMINAL_CONTRACT_STAGE="encode")
            run(swift_command, swift, encode_env, "crossRepoLocalTerminal() passed")
            ready = directory / "request-ready.json"
            if not ready.is_file() or not (directory / "input.json").is_file():
                raise SystemExit("FAIL: Swift did not encode create and keyboard requests")
            if defect == "keyboard":
                path = directory / "input.json"
                keyboard = json.loads(path.read_text())
                keyboard["type"] = "unknown_input"
                path.write_text(json.dumps(keyboard))
            elif defect == "intent":
                request = json.loads(ready.read_text())
                request["wrong_intent_key"] = request.pop("intent_id")
                ready.write_text(json.dumps(request))
            # Publishing this file releases Rust's request barrier only after
            # every Swift artifact (and the requested defect) is complete.
            ready.replace(directory / "request.json")
            status = process.wait(timeout=900)
            output.seek(0)
            transcript = output.read()
            expected = ("supervisor_http_contract_preserves_sessions_and_fences_stale_mutations ... FAILED"
                        if defect else "1 passed; 0 failed")
            if (status == 0) == bool(defect) or expected not in transcript:
                print(transcript)
                raise SystemExit("FAIL: Rust did not produce the required test verdict")
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=10)


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
        rust_command = ["cargo", "test", "-p", "server-rs", "--test", "local_terminal_metadata",
             "--jobs", "2", "supervisor_http_contract_preserves_sessions_and_fences_stale_mutations",
             "--", "--exact"]
        rust_exchange(rust_command, rust, command, swift, env, Path(temporary))
        if not (Path(temporary) / "response.json").is_file():
            raise SystemExit("FAIL: Rust did not produce HTTP and WebSocket evidence")
        env["SOYEHT_TERMINAL_CONTRACT_STAGE"] = "decode"
        run(command, swift, env, "crossRepoLocalTerminal() passed")
        # Calibrate against broken boundaries in disposable exchange files.
        # Compilation failure cannot satisfy these checks: the named test
        # must have executed and failed, not merely returned a nonzero code.
        response_path = Path(temporary) / "response.json"
        original = response_path.read_text()
        for defect in ("frame_prefix", "session_instance", "running_image", "broker_boot", "engine_broker"):
            response = json.loads(original)
            if defect == "frame_prefix":
                response["frames"][0][1] = 3
            elif defect == "session_instance":
                response["created"]["session_instance_id"] = "00000000-0000-4000-8000-000000000099"
            elif defect == "running_image":
                # Preserve semver and commit: neither proves the loaded image.
                original_uuid = response["engine"]["artifact"]["image_uuid"]
                response["engine"]["artifact"]["image_uuid"] = ("a" if original_uuid[0] != "a" else "b") + original_uuid[1:]
            elif defect == "broker_boot":
                response["supervisor"]["broker_boot_id"] = "00000000-0000-4000-8000-000000000099"
            else:
                response["engine"]["terminal_supervisor_boot_id"] = "00000000-0000-4000-8000-000000000099"
            response_path.write_text(json.dumps(response))
            run(command + ["--skip-build"], swift, env,
                "crossRepoLocalTerminal() failed", should_fail=True)
        response_path.write_text(original)
        for defect in ("keyboard", "intent"):
            rust_exchange(rust_command, rust, command + ["--skip-build"], swift, env,
                          Path(temporary), defect=defect)
    print("PASS: Swift requests executed by Rust; real HTTP/PTY frames and runtime identities decoded by Swift; 7 boundary defects rejected")


if __name__ == "__main__":
    main()
