#!/usr/bin/env python3
"""Offline fixtures for scheduler state, command boundaries and credential scope."""
import fcntl
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(sys.argv.pop(1))


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


reconcile = load("reconcile")
askpass = load("askpass")


class Reconciliation(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.base = Path(self.directory.name)
        self.calls = self.base / "calls.jsonl"
        self.binary = self.base / "ccid"
        self.binary.write_text(f"#!{sys.executable}\n" + """
import json, pathlib, sys
if sys.argv[1:] == ['source-revision']:
    print('a' * 40)
    sys.exit(0)
with pathlib.Path(__file__).with_name('calls.jsonl').open('a') as out:
    out.write(json.dumps(sys.argv[1:]) + '\\n')
repository = sys.argv[sys.argv.index('--repository') + 1]
if repository == 'invalid':
    print('invalid JSON')
    sys.exit(0)
complete = repository != 'offline'
print(json.dumps({'repository': repository, 'complete': complete,
                  'repository_complete': complete}))
sys.exit(0 if complete else 1)
""")
        self.binary.chmod(0o700)
        self.settings = {
            "binary": str(self.binary),
            "binary_sha256": hashlib.sha256(self.binary.read_bytes()).hexdigest(),
            "tool_revision": "a" * 40,
            "state_directory": str(self.base / "state"),
            "repositories": {name: {"policy_file": "/policy.json", "destinations": ["first", "second"],
                "interval_seconds": 600, "timeout_seconds": 10, "pause_seconds": 3}
                for name in ["offline", "online"]},
        }

    def report(self, repository):
        return json.loads((self.base / "state" / f"{repository}.json").read_text())

    @patch.object(reconcile.time, "sleep")
    def test_offline_continues_and_failure_survives_pacing(self, sleep):
        self.assertEqual(reconcile.run(self.settings), 1)
        commands = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(len(commands), 2)
        self.assertEqual(commands[1], ["forge", "sync", "--policy", "/policy.json", "--repository", "online",
            "--all-refs", "--apply", "--timeout", "10", "--to", "first", "--to", "second"])
        self.assertEqual(self.report("offline")["state"], "pending")
        self.assertTrue(self.report("online")["complete"])
        self.assertEqual(sleep.call_count, 2)
        self.assertEqual(reconcile.run(self.settings), 1)
        self.assertEqual(len(self.calls.read_text().splitlines()), 2)
        self.assertEqual(sleep.call_count, 2)

    def test_verification_refuses_before_git_and_clears_success(self):
        state = self.base / "state"
        state.mkdir()
        reconcile.atomic_json(state / "online.json", {"complete": True})
        self.settings["binary_sha256"] = "0" * 64
        self.assertEqual(reconcile.run(self.settings), 1)
        self.assertFalse(self.calls.exists())
        self.assertEqual(self.report("online")["reason"], "binary-verification-failed")
        self.settings["binary_sha256"] = hashlib.sha256(self.binary.read_bytes()).hexdigest()
        self.settings["tool_revision"] = "b" * 40
        self.assertEqual(reconcile.run(self.settings), 1)
        self.assertFalse(self.calls.exists())

    def test_lock_prevents_concurrent_pass(self):
        state = self.base / "state"
        state.mkdir()
        with (state / "reconcile.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(reconcile.run(self.settings), 75)
        self.assertFalse(self.calls.exists())

    @patch.object(reconcile.time, "sleep")
    def test_invalid_report_and_interrupted_attempt_remain_pending(self, _sleep):
        self.settings["repositories"] = {"invalid": self.settings["repositories"]["online"]}
        self.assertEqual(reconcile.run(self.settings), 1)
        self.assertFalse(self.report("invalid")["complete"])
        report = self.report("invalid")
        report["reason"] = "in-progress"
        reconcile.atomic_json(self.base / "state" / "invalid.json", report)
        self.assertEqual(reconcile.run(self.settings), 1)
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)


class Askpass(unittest.TestCase):
    def setUp(self):
        self.rules = {"https://forge.example": {"username": "robot", "passwordCommand":
            [sys.executable, "-c", "print('fixture-password')"]}}

    def test_exact_origin_and_username(self):
        self.assertEqual(askpass.answer(self.rules, "Username for 'https://forge.example': "), "robot")
        self.assertEqual(askpass.answer(self.rules, "Password for 'https://robot@forge.example/team/repo': "), "fixture-password")

    @patch.object(askpass.subprocess, "run")
    def test_spoofed_origin_and_unexpected_userinfo_never_run_command(self, command):
        for location in ["https://robot@forge.example.evil", "https://forge.example@evil.example",
                         "https://other@forge.example", "https://robot:secret@forge.example",
                         "https://robot@forge.example:444", "http://robot@forge.example",
                         "https://robot@forge.example?host=evil", "https://forge.example"]:
            self.assertIsNone(askpass.answer(self.rules, f"Password for '{location}': "))
        self.assertIsNone(askpass.answer(self.rules, "Username for 'https://robot@forge.example': "))
        self.assertIsNone(askpass.answer(self.rules, "arbitrary prompt"))
        command.assert_not_called()

    def test_command_failure_does_not_print_secret(self):
        with tempfile.TemporaryDirectory() as directory:
            rules = Path(directory) / "rules.json"
            self.rules["https://forge.example"]["passwordCommand"] = [sys.executable, "-c",
                "import sys; print('fixture-secret', file=sys.stderr); sys.exit(1)"]
            rules.write_text(json.dumps(self.rules))
            result = subprocess.run([sys.executable, str(ROOT / "scripts" / "askpass.py"), str(rules),
                "Password for 'https://robot@forge.example': "], capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout + result.stderr, b"")


if __name__ == "__main__":
    unittest.main()
