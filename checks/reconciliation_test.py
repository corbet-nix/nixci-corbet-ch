#!/usr/bin/env python3
"""Offline fixtures for scheduler state, command boundaries and credential scope."""
import fcntl
import hashlib
import importlib.util
import json
import os
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
        self.binary.write_text(f"#!{sys.executable}\nCALLS_PATH = {str(self.calls)!r}\n" + """
import json, pathlib, sys
if sys.argv[1:] == ['source-revision']:
    print('a' * 40)
    sys.exit(0)
with pathlib.Path(CALLS_PATH).open('a') as out:
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

    @patch.object(reconcile, "time", wraps=reconcile.time)
    def test_offline_continues_and_failure_survives_pacing(self, clock):
        sleep = clock.sleep
        sleep.return_value = None
        self.assertEqual(reconcile.run(self.settings), 75)
        commands = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(len(commands), 2)
        self.assertEqual(commands[1], ["forge", "sync", "--policy", "/policy.json", "--repository", "online",
            "--all-refs", "--apply", "--timeout", "10", "--to", "first", "--to", "second"])
        self.assertEqual(self.report("offline")["state"], "pending")
        self.assertTrue(self.report("online")["complete"])
        self.assertEqual(sleep.call_count, 2)
        self.assertEqual(reconcile.run(self.settings), 75)
        self.assertEqual(len(self.calls.read_text().splitlines()), 2)
        self.assertEqual(sleep.call_count, 2)

    def test_verification_refuses_before_git_and_clears_success(self):
        state = self.base / "state"
        state.mkdir(mode=0o700)
        reconcile.atomic_json(state / "online.json", {"complete": True})
        self.settings["binary_sha256"] = "0" * 64
        self.assertEqual(reconcile.run(self.settings), 1)
        self.assertFalse(self.calls.exists())
        self.assertEqual(self.report("online")["reason"], "binary-or-state-verification-failed")
        self.settings["binary_sha256"] = hashlib.sha256(self.binary.read_bytes()).hexdigest()
        self.settings["tool_revision"] = "b" * 40
        self.assertEqual(reconcile.run(self.settings), 1)
        self.assertFalse(self.calls.exists())

    def test_lock_prevents_concurrent_pass(self):
        state = self.base / "state"
        state.mkdir(mode=0o700)
        with reconcile.regular_file(state / "reconcile.lock", os.O_WRONLY | os.O_CREAT) as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(reconcile.run(self.settings), 75)
        self.assertFalse(self.calls.exists())

    @patch.object(reconcile, "time", wraps=reconcile.time)
    def test_invalid_report_and_interrupted_attempt_remain_pending(self, clock):
        clock.sleep.return_value = None
        self.settings["repositories"] = {"invalid": self.settings["repositories"]["online"]}
        self.assertEqual(reconcile.run(self.settings), 1)
        self.assertFalse(self.report("invalid")["complete"])
        self.assertEqual(reconcile.run(self.settings), 1)  # Invalid output stays fatal while paced.
        report = self.report("invalid")
        report["reason"] = "in-progress"
        reconcile.atomic_json(self.base / "state" / "invalid.json", report)
        self.assertEqual(reconcile.run(self.settings), 75)
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)

    @patch.object(reconcile, "time", wraps=reconcile.time)
    def test_binary_path_replacement_cannot_replace_verified_executable(self, clock):
        clock.sleep.return_value = None
        original_run = subprocess.run
        def replace_after_identity(command, **kwargs):
            result = original_run(command, **kwargs)
            if command[1:] == ["source-revision"]:
                replacement = self.base / "replacement"
                replacement.write_text("#!/bin/sh\nexit 99\n")
                replacement.chmod(0o700)
                replacement.replace(self.binary)
            return result
        with patch.object(reconcile.subprocess, "run", side_effect=replace_after_identity):
            self.assertEqual(reconcile.run(self.settings), 75)  # offline remains pending
        self.assertTrue(self.report("online")["complete"])
        self.assertEqual(len(self.calls.read_text().splitlines()), 2)

    def test_sealed_snapshot_cannot_be_modified(self):
        with reconcile.verified_binary(self.settings) as (executable, descriptor):
            with self.assertRaises(OSError):
                os.write(descriptor, b"overwrite")
            with self.assertRaises(OSError):
                os.truncate(executable, 0)

    def test_state_and_lock_symlinks_hardlinks_and_permissions_fail_closed(self):
        state = self.base / "state"
        outside = self.base / "outside"
        outside.mkdir(mode=0o700)
        state.symlink_to(outside, target_is_directory=True)
        self.assertEqual(reconcile.run(self.settings), 1)
        self.assertEqual(list(outside.iterdir()), [])
        state.unlink()
        state.mkdir(mode=0o755)
        self.assertEqual(reconcile.run(self.settings), 1)
        self.assertEqual(list(state.iterdir()), [])
        state.chmod(0o700)
        victim = outside / "victim"
        victim.write_text("preserved")
        victim.chmod(0o600)
        lock = state / "reconcile.lock"
        lock.symlink_to(victim)
        self.assertEqual(reconcile.run(self.settings), 1)
        lock.unlink()
        os.link(victim, lock)
        self.assertEqual(reconcile.run(self.settings), 1)
        lock.unlink()
        os.mkfifo(lock, mode=0o600)
        self.assertEqual(reconcile.run(self.settings), 1)
        self.assertEqual(victim.read_text(), "preserved")
        self.assertFalse(self.calls.exists())

    @patch.object(reconcile, "time", wraps=reconcile.time)
    def test_report_symlink_is_replaced_without_reading_or_overwriting_target(self, clock):
        clock.sleep.return_value = None
        state = self.base / "state"
        state.mkdir(mode=0o700)
        victim = self.base / "victim"
        payload = json.dumps({"complete": True, "attempt_started": reconcile.time.time()})
        victim.write_text(payload)
        (state / "online.json").symlink_to(victim)
        self.assertEqual(reconcile.run(self.settings), 75)
        self.assertTrue(self.report("online")["complete"])
        self.assertEqual(len(self.calls.read_text().splitlines()), 2)
        self.assertEqual(victim.read_text(), payload)
        self.assertEqual((state / "online.json").stat().st_mode & 0o777, 0o600)

    def test_repository_path_traversal_is_refused_before_execution(self):
        self.settings["repositories"] = {"../escape": self.settings["repositories"]["online"]}
        self.assertEqual(reconcile.run(self.settings), 1)
        self.assertFalse((self.base / "escape.json").exists())
        self.assertFalse(self.calls.exists())



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

    @patch.object(askpass.subprocess, "run")
    def test_control_characters_and_oversized_prompts_never_run_command(self, command):
        for location in ["https://robot@forge.exa\tmple", "https://robot@forge.example/\x00", "https://robot@forge.example/" + "a" * 4096]:
            self.assertIsNone(askpass.answer(self.rules, f"Password for '{location}': "))
        command.assert_not_called()

    def test_oversized_credential_output_is_refused(self):
        self.rules["https://forge.example"]["passwordCommand"] = [sys.executable, "-c", "print('a' * 5000)"]
        self.assertIsNone(askpass.answer(self.rules, "Password for 'https://robot@forge.example': "))

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
