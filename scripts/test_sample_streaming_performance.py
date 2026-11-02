"""Offline regression tests for the streamed UI diagnostics sampler."""
import json
import pathlib
import tempfile
import unittest

from sample_streaming_performance import new_diagnostic_records


class StreamSamplerLogTests(unittest.TestCase):
    def test_only_new_records_are_returned(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            path = root / "runtime-000.jsonl"
            path.write_text(json.dumps({"event": "old"}) + "\n")
            stat = path.stat()
            cursors = {path: ((stat.st_dev, stat.st_ino), stat.st_size)}
            pending = {}
            self.assertEqual(list(new_diagnostic_records(root, cursors, pending)), [])
            with path.open("a") as handle:
                handle.write(json.dumps({"event": "stream_performance", "fields": {"finalChars": "30000"}}) + "\n")
            records = list(new_diagnostic_records(root, cursors, pending))
            self.assertEqual(len(records), 1)
            self.assertEqual(records[0]["fields"]["finalChars"], "30000")
            self.assertEqual(list(new_diagnostic_records(root, cursors, pending)), [])

    def test_partial_line_and_new_rotated_log(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            path = root / "runtime-000.jsonl"
            path.write_bytes(b'{"event": "stream_perfor')
            cursors = {}
            pending = {}
            self.assertEqual(list(new_diagnostic_records(root, cursors, pending)), [])
            with path.open("ab") as handle:
                handle.write(b'mance", "fields": {"finalChars": "50000"}}\n')
            records = list(new_diagnostic_records(root, cursors, pending))
            self.assertEqual(records[0]["fields"]["finalChars"], "50000")
            rotated = root / "runtime-001.jsonl"
            rotated.write_text(json.dumps({"event": "stream_performance", "fields": {"finalChars": "100000"}}) + "\n")
            records = list(new_diagnostic_records(root, cursors, pending))
            self.assertEqual(len(records), 1)
            self.assertEqual(records[0]["fields"]["finalChars"], "100000")

    def test_truncated_file_restarts_at_zero(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            path = root / "runtime-000.jsonl"
            path.write_text(json.dumps({"event": "older-and-longer-record"}) + "\n")
            cursors = {}
            pending = {}
            self.assertEqual(len(list(new_diagnostic_records(root, cursors, pending))), 1)
            path.write_text('{"event":"new"}\n')
            self.assertEqual([r["event"] for r in new_diagnostic_records(root, cursors, pending)], ["new"])


if __name__ == "__main__":
    unittest.main()
