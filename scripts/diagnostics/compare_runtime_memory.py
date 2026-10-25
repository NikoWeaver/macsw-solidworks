"""Short local CAD/observer differential; caller owns cold host startup.

Run with the App's native Python. Never attaches COM, restarts SW, changes
renderer policy or touches pre-existing documents. The selected host must be
daemon-owned and empty. Cases come from the shared CLI gate, not copied CAD logic.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "memory_driving_gate", ROOT / "Dependencies/SWCLI/scripts/ci/verify-driving-dimensions.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def unix_host_pid():
    text = subprocess.run(["/bin/ps", "-axo", "pid=,comm="], check=True,
                          capture_output=True, text=True, timeout=5).stdout
    targets = [int(line.split(None, 1)[0]) for line in text.splitlines()
               if line.rstrip().lower().endswith("\\sldworks.exe")]
    gate.require(len(targets) == 1, "memory probe requires exactly one native SW process")
    return targets[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--sample", choices=("off", "periodic"), default="off")
    parser.add_argument("--iterations", type=int, choices=range(1, 6), default=2)
    args = parser.parse_args()
    directory = args.output_dir.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    helper = args.cli.parent.parent / "Resources/SWCLI/bin/swcli-path"
    mapped = subprocess.run([str(helper), str(directory)], check=True,
                            capture_output=True, text=True, timeout=10).stdout.strip()
    smoke = gate.DrivingSmoke(endpoint=os.environ.get("SWCLI_ENDPOINT", "127.0.0.1:18495"),
                              session="memory-" + uuid.uuid4().hex[:12],
                              output_directory=mapped, local_output_directory=directory,
                              cli=[str(args.cli.resolve())], request_timeout_seconds=600)
    health = smoke.call("daemon.health")
    gate.require(health["host_connected"] and health["host"]["owned_by_daemon"]
                 and not health["host"]["shared_interactive"], "exclusive connected host required")
    smoke.require_empty("before-memory-probe")
    pid = unix_host_pid()
    record = {"sample": args.sample, "iterations": args.iterations,
              "unix_pid": pid, "host": health["host"], "snapshots": []}
    def snapshot(label):
        result = subprocess.run(["/usr/bin/vmmap", "-summary", str(pid)],
                                capture_output=True, text=True, timeout=30)
        (directory / (label + "-vmmap.log")).write_text(result.stdout + result.stderr)
        row = {"stage": label, "vmmap_exit_code": result.returncode,
               "footprint": re.findall(r"^Physical footprint[^\n]*", result.stdout, re.M)}
        record["snapshots"].append(row)
        print(json.dumps(row), flush=True)
    stopped = threading.Event()
    def sample_periodically():
        count = 0
        while not stopped.is_set():
            count += 1
            path = directory / ("sample-" + str(count).zfill(3) + ".log")
            try:
                subprocess.run(["/usr/bin/sample", str(pid), "2", "10", "-file", str(path)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
            except (OSError, subprocess.SubprocessError):
                pass  # Diagnostic failure does not fabricate a business result.
            if stopped.wait(60):
                break
    observer = threading.Thread(target=sample_periodically, daemon=True)
    started = time.monotonic()
    try:
        snapshot("before")
        smoke.prepare_origin_fixture()
        if args.sample == "periodic":
            observer.start()
        for i in range(args.iterations):
            iteration = directory / ("iteration-" + str(i + 1))
            iteration.mkdir()
            smoke.output_directory = gate.host_path(mapped, iteration.name)
            smoke.center_constraints("front")
            smoke.require_empty("center-" + str(i + 1))
            gate.require(smoke.call("daemon.health")["host"]["process_id"]
                         == health["host"]["process_id"], "host replacement during memory probe")
            snapshot("after-" + str(i + 1))
        record["success"] = True
    except Exception as error:
        record["success"] = False
        record["error"] = {"type": type(error).__name__, "message": str(error)}
        raise
    finally:
        stopped.set()
        if observer.is_alive():
            observer.join(35)
        record["cleanup_errors"] = smoke.cleanup()
        if record["cleanup_errors"]:
            record["success"] = False
        record["seconds"] = time.monotonic() - started
        (directory / "memory.json").write_text(json.dumps(record, indent=2))
        (directory / "driving-dimensions.json").write_text(json.dumps(smoke.record, indent=2))
    gate.require(not record["cleanup_errors"], "memory probe cleanup failed")


if __name__ == "__main__":
    main()
