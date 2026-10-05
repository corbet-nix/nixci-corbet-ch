#!/usr/bin/env python3
"""One sequential, locked reconciliation pass over an explicit allowlist."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def atomic_json(path, value):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            json.dump(value, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
            os.replace(temporary, path)
            descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        finally:
            temporary.unlink(missing_ok=True)


def read_report(path):
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def verify_binary(settings):
    expected = settings.get("binary_sha256")
    revision = settings.get("tool_revision")
    if expected is None and revision is None:
        return True
    if not expected or not revision:
        return False
    try:
        with open(settings["binary"], "rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        if digest != expected:
            return False
        result = subprocess.run([settings["binary"], "source-revision"], stdin=subprocess.DEVNULL,
                                capture_output=True, timeout=10)
        return result.returncode == 0 and result.stdout.decode().strip() == revision
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return False


def run(settings):
    state = Path(settings["state_directory"])
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = state / "tmp"
    temporary.mkdir(mode=0o700, exist_ok=True)
    with (state / "reconcile.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 75
        if not verify_binary(settings):
            for repository in settings["repositories"]:
                atomic_json(state / f"{repository}.json", {"schema": 1, "repository": repository,
                            "complete": False, "state": "pending", "reason": "binary-verification-failed",
                            "finished_at": time.time()})
            return 1
        failed = False
        for repository, entry in sorted(settings["repositories"].items()):
            report_path = state / f"{repository}.json"
            previous = read_report(report_path)
            started = time.time()
            last_attempt = previous.get("attempt_started", 0)
            if isinstance(last_attempt, (int, float)) and 0 <= started - last_attempt < entry["interval_seconds"]:
                failed |= previous.get("complete") is not True
                continue
            record = {"schema": 1, "repository": repository, "attempt_started": started,
                      "complete": False, "state": "pending", "reason": "in-progress"}
            # Persist intent before running so a crash never leaves stale success.
            atomic_json(report_path, record)
            command = [settings["binary"], "forge", "sync", "--policy", entry["policy_file"],
                       "--repository", repository, "--all-refs", "--apply", "--timeout", str(entry["timeout_seconds"])]
            for destination in entry["destinations"]:
                command.extend(["--to", destination])
            with tempfile.TemporaryFile(dir=temporary) as output:
                try:
                    result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=output,
                                            env={**os.environ, "TMPDIR": str(temporary)},
                                            timeout=entry["timeout_seconds"] + 30)
                    code = result.returncode
                    output.seek(0)
                    raw = output.read(16 * 1024 * 1024 + 1)
                    if len(raw) > 16 * 1024 * 1024:
                        raise ValueError("report-too-large")
                    report = json.loads(raw)
                    if not isinstance(report, dict) or report.get("repository") != repository or not isinstance(report.get("complete"), bool):
                        raise ValueError("invalid-report")
                    record.update(result=report, exit_code=code, complete=code == 0 and report["complete"],
                                  state="complete" if code == 0 and report["complete"] else "pending",
                                  reason="verified" if code == 0 and report["complete"] else "reconciliation-incomplete")
                except subprocess.TimeoutExpired:
                    # ccid normally enforces its own deadline and owns its Git
                    # process groups. Stop the service on a broken outer bound;
                    # systemd KillMode=control-group cleans all descendants.
                    record.update(reason="outer-timeout", finished_at=time.time())
                    atomic_json(report_path, record)
                    return 1
                except (OSError, ValueError) as error:
                    record.update(reason="unavailable-or-invalid-report", error_type=type(error).__name__)
            record["finished_at"] = time.time()
            atomic_json(report_path, record)
            failed |= not record["complete"]
            time.sleep(entry["pause_seconds"])
        return int(failed)


if __name__ == "__main__":
    with open(sys.argv[1]) as stream:
        sys.exit(run(json.load(stream)))
