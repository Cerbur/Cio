#!/usr/bin/env python3
"""Check current workspace invariants in the compatibility diagnostic report.

The binary's historical --spaces-self-test/--tabs-self-test output is preserved.
Three old address-focus assertions describe the retired shared-editor design;
they are explicitly reported as retired coverage, never as passing checks.
Current native focus and IME interactions remain in the manual checklist.
"""
from pathlib import Path
import re
import sys


def check(text, exit_code):
    retired = {
        "tab-change-keeps-address-focus",
        "address-field-owns-keyboard-before-space-switch",
        "space-switch-does-not-steal-address-focus",
    }
    rows = re.findall(r"^(?:spaces|tabs)-self-test: (pass|FAIL) (\S+) -", text, re.M)
    summary = re.search(r"(?:spaces|tabs)-self-test: checks=(\d+) failures=(\d+)", text)
    errors = []
    failed = {name for result, name in rows if result == "FAIL"}
    passed = {name for result, name in rows if result == "pass"}
    if not summary or len(rows) != int(summary[1]) or len(failed) != int(summary[2]):
        errors.append("missing or inconsistent diagnostic summary")
    if exit_code != (2 if failed else 0):
        errors.append(f"unexpected diagnostic exit {exit_code}")
    for name in sorted(failed - retired):
        errors.append(f"current workspace invariant failed: {name}")
    required = {
        "three-spaces-created", "multiple-tabs-per-space",
        "distinct-space-browser-identities", "all-existing-sessions-created-once",
        "independent-space-selections", "switch-spaces-does-not-recreate",
        "only-selected-space-tab-is-visible", "background-browser-does-not-take-focus",
        "late-space-browser-stays-hidden", "background-close-keeps-active-page-focus",
        "inactive-space-callback-keeps-selection", "last-tab-replacement-stays-in-space",
        "reopen-creates-new-runtime", "popup-from-inactive-space-uses-source-space",
        "inactive-popup-does-not-switch-space-or-focus",
        "all-spaces-shutdown-closes-every-runtime",
        "termination-creates-no-replacement-or-history",
        "onbeforeclose-before-cef-shutdown", "shutdown-waits-for-onbeforeclose",
        "cef-shutdown-once",
    }
    for name in sorted(required - passed):
        errors.append(f"missing current workspace check: {name}")
    if text.count("lifecycle: cef:shutdown(clean: true)") != 1:
        errors.append("expected one clean CEF shutdown")
    for name in sorted(failed & retired):
        print(f"[retired coverage; not a pass] {name}")
    for error in errors:
        print(f"FAIL: {error}")
    if not errors:
        print(f"PASS: {len(passed - retired)} current workspace checks")
    return bool(errors)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: check_workspace_report.py LOG EXIT_CODE")
    sys.exit(check(Path(sys.argv[1]).read_text(), int(sys.argv[2])))
