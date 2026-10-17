#!/usr/bin/env python3
"""Run a build step only when its inputs are newer, with nanosecond precision.

The make 3.81 shipped with macOS compares whole seconds, which can miss quick
successive edits and configuration changes. Keep dependency ordering in make,
but use filesystem precision to decide whether each step needs to run.
"""
from pathlib import Path
import subprocess
import sys


def main():
    separator = sys.argv.index("--")
    target = Path(sys.argv[1])
    inputs = [Path(value) for value in sys.argv[2:separator]]
    command = sys.argv[separator + 1:]
    if target.exists() and all(path.stat().st_mtime_ns <= target.stat().st_mtime_ns for path in inputs):
        return 0
    print(" ".join(command), flush=True)
    return subprocess.call(command)


if __name__ == "__main__":
    sys.exit(main())
