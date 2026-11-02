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


def new_diagnostic_records(directory, cursors, partial_lines):
    """Read only new complete JSONL records across log rotation/recreation.

    Re-reading every growing diagnostics file on each 500 ms sample can consume
    significant CPU and make the stream under measurement appear slower.
    """
    for path in sorted(directory.glob("*.jsonl")):
        stat = path.stat()
        identity = (stat.st_dev, stat.st_ino)
        previous = cursors.get(path)
        offset = previous[1] if previous and previous[0] == identity and stat.st_size >= previous[1] else 0
        if offset == 0:
            partial_lines.pop(path, None)
        with path.open("rb") as handle:
            handle.seek(offset)
            chunk = handle.read()
        cursors[path] = (identity, offset + len(chunk))
        if not chunk:
            continue
        lines = (partial_lines.pop(path, b"") + chunk).split(b"\n")
        partial_lines[path] = lines.pop()
        for line in lines:
            try:
                yield json.loads(line.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue


def measure(udid, chars):
    root = pathlib.Path(simctl("get_app_container", udid, "com.remoteai.mobile", "data"))
    logs = root / "Library/Application Support/RemoteAI/Diagnostics"
    cursors = {}
    for path in logs.glob("*.jsonl"):
        stat = path.stat()
        cursors[path] = ((stat.st_dev, stat.st_ino), stat.st_size)
    # Old files resume at EOF; newly rotated files start at byte zero.
    partial_lines = {}
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
        # The fixture emits 100 graphemes every 50 ms, but simulator app
        # startup, actor initialization and final disk logging are asynchronous.
        # The old +20 s deadline was too tight on loaded Intel CI runners.
        # Keep a bounded startup/reconciliation allowance without weakening
        # the canonical comparison or skipping any length.
        deadline = time.monotonic() + chars / 2000 + 90
        observed = {}
        while time.monotonic() < deadline:
            for record in new_diagnostic_records(logs, cursors, partial_lines):
                event = record.get("event")
                if not isinstance(event, str):
                    continue
                observed[event] = observed.get(event, 0) + 1
                if event == "stream_performance" and record.get("fields", {}).get("finalChars") == str(chars):
                    final = record
            if final is not None:
                break
            time.sleep(0.5)
        if final is None:
            # Save non-sensitive event counts for the CI artifact: distinguish a
            # startup/fixture failure from a missing terminal reconciliation.
            (output / "diagnostic-summary.json").write_text(json.dumps({
                "chars": chars, "eventCounts": observed,
                "logFileCount": len(list(logs.glob("*.jsonl")))
            }, indent=2, sort_keys=True))
            raise RuntimeError(f"No canonical stream completion observed for {chars}; "
                               f"diagnostic events: {observed}")
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
