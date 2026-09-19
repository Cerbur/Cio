#!/usr/bin/env python3
"""Check a --log-shutdown-timing run, including real Cmd+Q recordings.

Usage: python3 Scripts/check_shutdown_timing.py LOG PROCESS_EXIT_CODE [MAX_MS]
This checks captured evidence; it does not generate native keyboard events.
"""
import re
import sys
from pathlib import Path


def check(text, exit_code, max_ms):
    errors = []
    if exit_code != 0:
        errors.append(f"process exited {exit_code}, expected 0")
    phases = {}
    for name, ms in re.findall(r"shutdown-phase: (\S+) \+([\d.]+)ms", text):
        phases.setdefault(name, []).append(float(ms))
    order = ["T0", "T1", "T2", "T3", "T4", "T5", "T6", "T7"]
    for name in order:
        if len(phases.get(name, [])) != 1:
            errors.append(f"{name}: expected exactly one timestamp")
    if all(phases.get(name) for name in order):
        times = [phases[name][0] for name in order]
        if times != sorted(times):
            errors.append("shutdown order violated: require T0→T1→T2→T3→T4→T5→T6→T7")
    elapsed = None
    if phases.get("T0") and phases.get("T7"):
        elapsed = phases["T7"][0] - phases["T0"][0]
        if elapsed > max_ms:
            errors.append(f"quit took {elapsed:.1f} ms, budget {max_ms:.0f} ms")
    for marker in ("termination:browser-close-timeout", "termination:skipped-cef-shutdown",
                   "termination:forced-view-release"):
        if marker in text:
            errors.append(f"unexpected fallback: {marker}")
    if "lifecycle: appkit:will-terminate" not in text:
        errors.append("missing final application termination")
    return errors, elapsed


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    errors, elapsed = check(Path(sys.argv[1]).read_text(), int(sys.argv[2]),
                            float(sys.argv[3]) if len(sys.argv) == 4 else 1000)
    if errors:
        for error in errors:
            print(f"FAIL: {error}")
        sys.exit(1)
    print(f"PASS: quit {elapsed:.1f} ms; exit 0; ordered browser/CEF cleanup; no fallback")
