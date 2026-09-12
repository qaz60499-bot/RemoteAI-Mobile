"""Measure the real mock streaming UI without XCTest accessibility snapshot pauses.

This complements, and never replaces, the composer/history UI assertions. Only
our named candidate simulator and explicitly gated in-memory mock app are used.
"""
import argparse
import json
import os
import pathlib
import subprocess
import threading
import time

from run_candidate_ui_tests import sample_app_process


def simctl(*args, env=None):
    return subprocess.run(["xcrun", "simctl", *args], check=True, timeout=45,
                          capture_output=True, text=True, env=env).stdout.strip()


def measure(udid, chars):
    root = pathlib.Path(simctl("get_app_container", udid, "com.remoteai.mobile", "data"))
    logs = root / "Library/Application Support/RemoteAI/Diagnostics"
    offsets = {p: p.stat().st_size for p in logs.glob("*.jsonl")}
    output = pathlib.Path("build/ui-evidence") / f"unattended-{chars}"
    output.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ)
    environment.update({"SIMCTL_CHILD_REMOTEAI_UI_TEST_MOCK": "1",
                        "SIMCTL_CHILD_REMOTEAI_UI_STRESS_DIRECT": "1",
                        "SIMCTL_CHILD_REMOTEAI_UI_STRESS_CHARS": str(chars),
                        "SIMCTL_CHILD_REMOTEAI_STREAM_FRAME_SAMPLING": "1"})
    stop = threading.Event()
    sampler = threading.Thread(target=sample_app_process,
                               args=(udid, output / "process.jsonl", stop), daemon=True)
    sampler.start()
    final = None
    try:
        simctl("launch", "--terminate-running-process", udid, "com.remoteai.mobile",
               "-UITestMockMode", "1", env=environment)
        # Fixture emits 100 graphemes every 50ms, plus startup/reconciliation.
        deadline = time.monotonic() + chars / 2000 + 20
        while time.monotonic() < deadline:
            for path in logs.glob("*.jsonl"):
                tail = path.read_bytes()[offsets.get(path, 0):].decode("utf-8", errors="replace")
                for line in tail.splitlines():
                    try:
                        record = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if record.get("event") == "stream_performance" and record["fields"].get("finalChars") == str(chars):
                        final = record
            if final is not None:
                break
            time.sleep(0.5)
        if final is None:
            raise RuntimeError(f"No canonical stream completion observed for {chars}")
        (output / "performance.json").write_text(json.dumps(final, indent=2))
        assert final["fields"]["canonicalEqual"] == "true", "Canonical text mismatch"
        print("UNATTENDED_STREAM " + json.dumps(final["fields"], sort_keys=True), flush=True)
    finally:
        stop.set()
        sampler.join(timeout=6)
        simctl("io", udid, "screenshot", str(output / "screen.png"))
        # Terminate this mock launch only; real devices are never addressed here.
        subprocess.run(["xcrun", "simctl", "terminate", udid, "com.remoteai.mobile"], timeout=30)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--udid", required=True)
    args = parser.parse_args()
    devices = json.loads(simctl("list", "devices", "-j"))
    selected = [d for rows in devices["devices"].values() for d in rows if d["udid"] == args.udid]
    assert len(selected) == 1 and selected[0]["name"].startswith("RemoteAI-Candidate-"), "Not a candidate simulator"
    for chars in [30_000, 50_000, 100_000]:
        measure(args.udid, chars)


if __name__ == "__main__":
    main()
