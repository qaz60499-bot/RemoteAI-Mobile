"""Run every XCTest UI method with a freshly booted candidate simulator.

An app process left by the preceding test previously made XCUIApplication.launch
spend a minute failing to terminate it. Reboot only our disposable CI simulator
between tests; preserve all tests/assertions and fail on any test/cleanup error.
"""
import argparse
import json
import pathlib
import re
import subprocess
import shutil
import threading
import time
import os
import signal


def run(command, timeout, capture=False):
    print("+ " + " ".join(command), flush=True)
    return subprocess.run(command, check=True, timeout=timeout, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def sample_app_process(udid, output, stop):
    """Host ps CPU is a time average; RSS is the simulator process, not device RAM."""
    with output.open("w") as stream:
        while not stop.is_set():
            try:
                rows = subprocess.run(["ps", "-axo", "pid=,%cpu=,rss=,command="],
                                      capture_output=True, text=True, timeout=5)
                for line in rows.stdout.splitlines():
                    if udid not in line or "/RemoteAI.app/RemoteAI" not in line:
                        continue
                    pid, cpu, rss, _ = line.strip().split(None, 3)
                    stream.write(json.dumps({"hostTime": time.time(), "pid": int(pid),
                                             "psAverageCPUPercent": float(cpu),
                                             "residentBytes": int(rss) * 1024}) + "\n")
                    stream.flush()
            except (subprocess.TimeoutExpired, ValueError) as error:
                stream.write(json.dumps({"samplingError": str(error)}) + "\n")
            stop.wait(1)


def run_test(command, evidence):
    """Keep a live log and kill only this invocation's process group on timeout."""
    print("+ " + " ".join(command), flush=True)
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, start_new_session=True)
    def copy_output():
        with (evidence / "xcodebuild.log").open("w") as log:
            for line in process.stdout:
                log.write(line)
                log.flush()
                print(line, end="", flush=True)
    reader = threading.Thread(target=copy_output, daemon=True)
    reader.start()
    try:
        # Hosted runners can spend several minutes starting XCTest automation before
        # a long-stream UI case begins. Preserve the strict 300s budget for ordinary
        # UI tests, but let the explicit 30k/50k streaming cases cover that startup
        # cost plus their deterministic stream duration.
        timeout = 480 if any("LongStreaming" in part for part in command) else 300
        code = process.wait(timeout=timeout)
        if code:
            raise subprocess.CalledProcessError(code, command)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
        raise
    finally:
        reader.join(timeout=10)


def preserve_evidence(udid, evidence):
    # Diagnostics must not replace the original test/timeout failure.
    errors = []
    def attempt(command):
        try:
            result = subprocess.run(command, timeout=30, capture_output=True, text=True)
            if result.returncode:
                errors.append({"command": command, "error": result.stderr})
            return result
        except subprocess.TimeoutExpired:
            errors.append({"command": command, "error": "timeout"})
            return None
    attempt(["xcrun", "xcresulttool", "export", "attachments", "--path",
             str(evidence / "result.xcresult"), "--output-path", str(evidence / "attachments")])
    container = attempt(["xcrun", "simctl", "get_app_container", udid, "com.remoteai.mobile", "data"])
    if container is not None and container.returncode == 0:
        logs = pathlib.Path(container.stdout.strip()) / "Library/Application Support/RemoteAI/Diagnostics"
        if logs.exists():
            shutil.copytree(logs, evidence / "diagnostics", dirs_exist_ok=True)
    attempt(["xcrun", "simctl", "io", udid, "screenshot", str(evidence / "screen.png")])
    (evidence / "collection-errors.json").write_text(json.dumps(errors, indent=2))


def boot_candidate(udid):
    devices = json.loads(run(["xcrun", "simctl", "list", "devices", "-j"], 45, True))
    selected = [d for rows in devices["devices"].values() for d in rows if d["udid"] == udid]
    assert len(selected) == 1 and selected[0]["name"].startswith("RemoteAI-Candidate-"), "Candidate simulator missing"
    if selected[0]["state"] != "Shutdown":
        run(["xcrun", "simctl", "shutdown", udid], 60)
    run(["xcrun", "simctl", "boot", udid], 60)
    run(["xcrun", "simctl", "bootstatus", udid, "-b"], 120)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--udid", required=True)
    parser.add_argument("--only", action="append", help="Run a discovered test method (repeatable)")
    args = parser.parse_args()
    assert re.fullmatch(r"[A-Fa-f0-9-]{36}", args.udid)
    methods = []
    for path in sorted(pathlib.Path("RemoteAIMobileUITests").glob("*.swift")):
        source = path.read_text()
        suites = re.findall(r"(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase", source)
        if not suites:
            continue
        assert len(suites) == 1, f"Explicit suite discovery required for {path}"
        methods += [f"RemoteAIMobileUITests/{suites[0]}/{name}" for name in
                    re.findall(r"func\s+(test\w+)\s*\(", source)]
    assert methods, "No UI tests discovered"
    if args.only:
        methods = [m for m in methods if m.rsplit("/", 1)[-1] in args.only]
        assert len(methods) == len(set(args.only)), "Requested UI test was not discovered"
    # Exercise the changed behavior before spending time on navigation regressions.
    methods.sort(key=lambda method: ("LongStreaming" not in method, method))
    # Compile once, outside the per-method simulator launch deadline.
    run(["xcodebuild", "build-for-testing", "-project", "RemoteAIMobile.xcodeproj",
         "-scheme", "RemoteAIMobile", "-configuration", "Debug",
         "-destination", f"platform=iOS Simulator,id={args.udid}"], 600)
    for method in methods:
        for attempt in range(2):
            boot_candidate(args.udid)
            evidence = pathlib.Path("build/ui-evidence") / method.rsplit("/", 1)[-1] / f"attempt-{attempt + 1}"
            evidence.mkdir(parents=True, exist_ok=True)
            stop_sampling = threading.Event()
            sampler = threading.Thread(target=sample_app_process,
                                       args=(args.udid, evidence / "process.jsonl", stop_sampling), daemon=True)
            sampler.start()
            startup_timeout = False
            try:
                run_test(["xcodebuild", "test-without-building", "-project", "RemoteAIMobile.xcodeproj",
                          "-scheme", "RemoteAIMobile", "-configuration", "Debug",
                          "-destination", f"platform=iOS Simulator,id={args.udid}",
                          "-resultBundlePath", str(evidence / "result.xcresult"),
                          "-parallel-testing-enabled", "NO", f"-only-testing:{method}"], evidence)
            except subprocess.TimeoutExpired:
                test_started = "Test Case '-[" in (evidence / "xcodebuild.log").read_text()
                app_sampled = '"pid"' in (evidence / "process.jsonl").read_text()
                if attempt or test_started or app_sampled:
                    raise
                startup_timeout = True
            finally:
                stop_sampling.set()
                sampler.join(timeout=6)
                preserve_evidence(args.udid, evidence)
            if not startup_timeout:
                break
            print("SIMULATOR_STARTUP_RECOVERY_ONCE: no test case or app process started", flush=True)
            # This service is on the disposable hosted runner, never the user's host.
            run(["killall", "-9", "com.apple.CoreSimulator.CoreSimulatorService"], 15)
    print(f"CANDIDATE_UI_TESTS_PASS={len(methods)}", flush=True)


if __name__ == "__main__":
    main()
