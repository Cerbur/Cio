#!/usr/bin/env python3
"""Run one GUI test process in the foreground with an external timeout."""

from __future__ import annotations

import os
import signal
import subprocess
import sys


def shell_exit_status(returncode: int) -> int:
    """Translate Python's negative signal status to the shell's convention."""
    return returncode if returncode >= 0 else 128 + (-returncode)


def stop_process_group(process: subprocess.Popen[object]) -> None:
    """Stop only the process group created for this test invocation."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return

    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass

    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    process.wait()


def main() -> int:
    if len(sys.argv) < 3:
        print(
            "usage: run_gui_process_with_timeout.py SECONDS COMMAND [ARGUMENT ...]",
            file=sys.stderr,
        )
        return 2

    try:
        timeout = float(sys.argv[1])
    except ValueError:
        print(f"invalid timeout: {sys.argv[1]}", file=sys.stderr)
        return 2
    if timeout < 0:
        print("timeout must be non-negative", file=sys.stderr)
        return 2

    try:
        process = subprocess.Popen(
            sys.argv[2:],
            start_new_session=True,
        )
    except OSError as error:
        print(f"could not launch test process: {error}", file=sys.stderr)
        return 127

    try:
        return shell_exit_status(process.wait(timeout=timeout))
    except subprocess.TimeoutExpired:
        stop_process_group(process)
        return 124


if __name__ == "__main__":
    raise SystemExit(main())
