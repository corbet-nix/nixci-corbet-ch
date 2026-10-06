#!/usr/bin/env python3
"""One sequential, locked reconciliation pass over an explicit allowlist."""
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
import re
import stat
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


def regular_file(path, flags=os.O_RDONLY, mode=0o600):
    descriptor = os.open(path, flags | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, mode)
    info = os.fstat(descriptor)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1 or info.st_mode & 0o077:
        os.close(descriptor)
        raise ValueError("unsafe-state-file")
    return os.fdopen(descriptor, "a" if flags & os.O_CREAT else "rb")


@contextmanager
def state_directory(path):
    # Walk with directory descriptors so no parent symlink can redirect writes.
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError("unsafe-state-directory")
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for index, part in enumerate(path.parts[1:]):
            if index == len(path.parts) - 2:
                try:
                    os.mkdir(part, 0o700, dir_fd=descriptor)
                except FileExistsError:
                    pass
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        info = os.fstat(descriptor)
        if info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise ValueError("unsafe-state-directory")
        yield Path(f"/proc/self/fd/{descriptor}")
    finally:
        os.close(descriptor)


def read_report(path):
    try:
        with regular_file(path) as stream:
            raw = stream.read(16 * 1024 * 1024 + 1)
        if len(raw) > 16 * 1024 * 1024:
            return {}
        value = json.loads(raw)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


@contextmanager
def verified_binary(settings):
    # Hash and execute the SAME sealed bytes, even if a cache path is replaced
    # or the original inode is modified after verification. Linux/NixOS only.
    expected = settings.get("binary_sha256")
    revision = settings.get("tool_revision")
    if not expected or not revision:
        raise ValueError("missing-binary-identity")
    descriptor = os.memfd_create("ccid-reconciliation", os.MFD_CLOEXEC | os.MFD_ALLOW_SEALING)
    try:
        source = os.open(settings["binary"], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
        with os.fdopen(source, "rb") as stream, os.fdopen(os.dup(descriptor), "wb") as snapshot:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise ValueError("invalid-binary-file")
            digest = hashlib.sha256()
            size = 0
            while chunk := stream.read(1024 * 1024):
                size += len(chunk)
                if size > 128 * 1024 * 1024:
                    raise ValueError("binary-too-large")
                digest.update(chunk)
                snapshot.write(chunk)
        fcntl.fcntl(descriptor, fcntl.F_ADD_SEALS,
                    fcntl.F_SEAL_WRITE | fcntl.F_SEAL_GROW | fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_SEAL)
        if digest.hexdigest() != expected:
            raise ValueError("binary-digest-mismatch")
        executable = f"/proc/self/fd/{descriptor}"
        # Bounded temporary output avoids buffering arbitrary identity output.
        with tempfile.TemporaryFile() as output:
            result = subprocess.run([executable, "source-revision"], stdin=subprocess.DEVNULL,
                                    stdout=output, stderr=subprocess.DEVNULL, timeout=10,
                                    pass_fds=(descriptor,))
            output.seek(0)
            identity = output.read(128)
        if result.returncode or identity.decode().strip() != revision:
            raise ValueError("binary-revision-mismatch")
        yield executable, descriptor
    finally:
        os.close(descriptor)


def run(settings):
    try:
        if not settings["repositories"] or any(not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}", name)
                                              for name in settings["repositories"]):
            raise ValueError("invalid-repository-name")
        with state_directory(settings["state_directory"]) as state:
            with regular_file(state / "reconcile.lock", os.O_WRONLY | os.O_CREAT) as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    return 75
                with verified_binary(settings) as binary, tempfile.TemporaryDirectory(prefix="ccid-reconcile-") as temporary:
                    return reconcile(settings, state, Path(temporary), binary)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        # Never leave a stale complete report after a failed verification. If
        # state itself is unsafe, do not follow it merely to publish an error.
        try:
            with state_directory(settings["state_directory"]) as state:
                with regular_file(state / "reconcile.lock", os.O_WRONLY | os.O_CREAT) as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    for repository in settings["repositories"]:
                        if re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}", repository):
                            atomic_json(state / f"{repository}.json", {"schema": 1, "repository": repository,
                                        "complete": False, "state": "pending", "reason": "binary-or-state-verification-failed",
                                        "finished_at": time.time()})
        except (OSError, ValueError):
            pass
        return 1


def reconcile(settings, state, temporary, binary):
    executable, descriptor = binary
    failed = False
    invalid = False
    for repository, entry in sorted(settings["repositories"].items()):
        report_path = state / f"{repository}.json"
        previous = read_report(report_path)
        started = time.time()
        last_attempt = previous.get("attempt_started", 0)
        if isinstance(last_attempt, (int, float)) and 0 <= started - last_attempt < entry["interval_seconds"]:
            failed |= previous.get("complete") is not True
            invalid |= previous.get("reason") in {"unavailable-or-invalid-report", "outer-timeout"}
            continue
        record = {"schema": 1, "repository": repository, "attempt_started": started,
                  "complete": False, "state": "pending", "reason": "in-progress"}
        # Persist intent before running so a crash never leaves stale success.
        atomic_json(report_path, record)
        command = [executable, "forge", "sync", "--policy", entry["policy_file"],
                   "--repository", repository, "--all-refs", "--apply", "--timeout", str(entry["timeout_seconds"])]
        for destination in entry["destinations"]:
            command.extend(["--to", destination])
        with tempfile.TemporaryFile(dir=temporary) as output:
            try:
                result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=output,
                                        env={**os.environ, "TMPDIR": str(temporary)},
                                        timeout=entry["timeout_seconds"] + 30, pass_fds=(descriptor,),
                                        stderr=subprocess.DEVNULL)
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
                invalid = True
        record["finished_at"] = time.time()
        atomic_json(report_path, record)
        failed |= not record["complete"]
        time.sleep(entry["pause_seconds"])
    # Offline/divergent replicas are expected scheduled outcomes, not broken
    # local execution. Preserve nonzero CLI status and incomplete reports while
    # distinguishing integrity/timeout failures from temporary incompleteness.
    return 1 if invalid else (75 if failed else 0)


if __name__ == "__main__":
    with open(sys.argv[1]) as stream:
        sys.exit(run(json.load(stream)))
