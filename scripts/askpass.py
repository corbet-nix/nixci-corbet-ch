#!/usr/bin/env python3
"""Answer only exact configured HTTPS-origin Git credential prompts."""
import json
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit


def answer(rules, prompt):
    match = re.fullmatch(r"(Username|Password) for '([^'\r\n]+)': ?", prompt)
    if not match:
        return None
    kind, location = match.groups()
    url = urlsplit(location)
    if url.scheme != "https" or not url.hostname or url.password is not None or url.query or url.fragment:
        return None
    origin = "https://" + url.hostname
    if url.port is not None:
        origin += f":{url.port}"
    rule = rules.get(origin)
    if not isinstance(rule, dict):
        return None
    username = rule["username"]
    if not username or any(character in username for character in "\r\n\0"):
        return None
    if kind == "Username":
        return username if url.username is None else None
    if url.username is None or unquote(url.username) != username:
        return None
    result = subprocess.run(rule["passwordCommand"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, timeout=30)
    if result.returncode:
        return None
    password = result.stdout.decode().rstrip("\r\n")
    return password if password and not any(character in password for character in "\r\n\0") else None


if __name__ == "__main__":
    try:
        with open(sys.argv[1]) as stream:
            value = answer(json.load(stream), sys.argv[2])
        if value is None:
            sys.exit(1)
        print(value)
    except (OSError, ValueError, KeyError, IndexError, TypeError, subprocess.TimeoutExpired):
        # Git handles refusal; never echo command output or credential configuration.
        sys.exit(1)
