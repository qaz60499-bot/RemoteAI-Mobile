"""Verify that simulator recovery cannot hide a started/failed UI test."""
import os
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import run_candidate_ui_tests as runner


class RecoveryGateTests(unittest.TestCase):
    def exercise(self, outcomes, expect_error=None):
        with tempfile.TemporaryDirectory() as directory:
            original = os.getcwd()
            os.chdir(directory)
            try:
                pathlib.Path("RemoteAIMobileUITests").mkdir()
                pathlib.Path("RemoteAIMobileUITests/Example.swift").write_text(
                    "final class Example: XCTestCase { func testExample() {} }")
                seen = []
                def fake_test(command, evidence):
                    state = outcomes[len(seen)]
                    seen.append(evidence)
                    (evidence / "xcodebuild.log").write_text("Test Case '-[Example testExample]'" if state == "started" else "")
                    (evidence / "process.jsonl").write_text('{"pid":42}\n' if state == "app" else "")
                    if state == "failed":
                        raise subprocess.CalledProcessError(65, command)
                    if state != "success":
                        raise subprocess.TimeoutExpired(command, 300)
                with patch("sys.argv", ["runner", "--udid", "00000000-0000-0000-0000-000000000000"]), \
                     patch.object(runner, "run") as commands, \
                     patch.object(runner, "boot_candidate"), \
                     patch.object(runner, "sample_app_process"), \
                     patch.object(runner, "preserve_evidence"), \
                     patch.object(runner, "run_test", side_effect=fake_test):
                    if expect_error:
                        with self.assertRaises(expect_error):
                            runner.main()
                    else:
                        runner.main()
                    recoveries = [c for c in commands.call_args_list if c.args[0][0] == "killall"]
                return seen, recoveries
            finally:
                os.chdir(original)

    def test_only_prelaunch_timeout_retries_once_with_distinct_evidence(self):
        seen, recoveries = self.exercise(["timeout", "success"])
        self.assertEqual(len(recoveries), 1)
        self.assertEqual(len(set(seen)), 2)

    def test_second_prelaunch_timeout_fails(self):
        seen, recoveries = self.exercise(["timeout", "timeout"], subprocess.TimeoutExpired)
        self.assertEqual(len(seen), 2)
        self.assertEqual(len(recoveries), 1)

    def test_started_test_timeout_never_retries(self):
        seen, recoveries = self.exercise(["started"], subprocess.TimeoutExpired)
        self.assertEqual(len(seen), 1)
        self.assertEqual(recoveries, [])

    def test_app_process_timeout_never_retries(self):
        seen, recoveries = self.exercise(["app"], subprocess.TimeoutExpired)
        self.assertEqual(len(seen), 1)
        self.assertEqual(recoveries, [])

    def test_assertion_failure_never_retries(self):
        seen, recoveries = self.exercise(["failed"], subprocess.CalledProcessError)
        self.assertEqual(len(seen), 1)
        self.assertEqual(recoveries, [])


if __name__ == "__main__":
    unittest.main()
