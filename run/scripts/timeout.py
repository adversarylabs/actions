#!/usr/bin/env python3
"""Bound the action's review command without changing CLI timeout semantics."""

import math
import os
import signal
import subprocess
import sys
import time


def timeout_seconds(value):
    try:
        seconds = float(value or "10") * 60
    except ValueError:
        seconds = 0
    if not math.isfinite(seconds) or seconds <= 0:
        raise ValueError("timeout-minutes must be a positive finite number")
    return seconds


def signal_group(process, sig):
    try:
        os.killpg(process.pid, sig)
    except ProcessLookupError:
        pass


def stop(process):
    signal_group(process, signal.SIGTERM)
    # Keep the grace period even if the leader exits: descendants may still be
    # alive, and must not outlive a timed-out review.
    time.sleep(5)
    # Reap an exited leader before signaling the remaining group (macOS can
    # reject signals to a group containing only an unreaped zombie).
    process.poll()
    signal_group(process, signal.SIGKILL)
    process.wait()


def main():
    try:
        seconds = timeout_seconds(os.environ.get("INPUT_TIMEOUT_MINUTES", ""))
    except ValueError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 2

    process = subprocess.Popen(sys.argv[1:], start_new_session=True)

    def cancel(signum, _frame):
        # Avoid reentry while shutting down after a runner cancellation.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        stop(process)
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, cancel)
    signal.signal(signal.SIGINT, cancel)
    try:
        code = process.wait(timeout=seconds)
        return code if code >= 0 else 128 - code
    except subprocess.TimeoutExpired:
        print(
            f"::error::Adversary review exceeded timeout-minutes ({seconds / 60:g}); terminating review.",
            file=sys.stderr,
            flush=True,
        )
        stop(process)
        return 124


if __name__ == "__main__":
    sys.exit(main())
