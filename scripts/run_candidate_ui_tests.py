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


def run(command, timeout, capture=False):
    print("+ " + " ".join(command), flush=True)
    return subprocess.run(command, check=True, timeout=timeout, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--udid", required=True)
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
    for method in methods:
        devices = json.loads(run(["xcrun", "simctl", "list", "devices", "-j"], 45, True))
        selected = [d for rows in devices["devices"].values() for d in rows if d["udid"] == args.udid]
        assert len(selected) == 1, "Candidate simulator missing"
        if selected[0]["state"] != "Shutdown":
            run(["xcrun", "simctl", "shutdown", args.udid], 60)
        run(["xcrun", "simctl", "boot", args.udid], 60)
        run(["xcrun", "simctl", "bootstatus", args.udid, "-b"], 120)
        run(["xcodebuild", "test", "-project", "RemoteAIMobile.xcodeproj",
             "-scheme", "RemoteAIMobile", "-configuration", "Debug",
             "-destination", f"platform=iOS Simulator,id={args.udid}",
             "-parallel-testing-enabled", "NO", f"-only-testing:{method}"], 300)
    print(f"CANDIDATE_UI_TESTS_PASS={len(methods)}", flush=True)


if __name__ == "__main__":
    main()
