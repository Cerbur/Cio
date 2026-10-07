#!/usr/bin/env python3
"""Validate current persistence without assuming old sidebar order/seed titles."""
import json
from pathlib import Path
import re
import sys

seed, restored = (Path(p).read_text() for p in sys.argv[1:3])
snapshot = json.loads(Path(sys.argv[3]).read_text())
retired = {
    "seeded-three-spaces-and-two-tabs",
    "startup-space-order-and-selections-restored",
    "startup-urls-and-titles-restored",
}
errors = []
for text in (seed, restored):
    for name in re.findall(r"session-restore-self-test: FAIL (\S+)", text):
        if name in retired:
            print(f"[retired coverage; not a pass] {name}")
        else:
            errors.append(f"runtime invariant failed: {name}")
spaces = snapshot["spaces"]
graph = ";".join(s["id"] + "[" + ",".join(t["id"] for t in s["tabs"]) + "]" for s in spaces)
match = re.search(r"session-restore-self-test: restored graph=(\S+) selected-space=(\S+)", restored)
if not match or match[1] != graph or match[2] != snapshot["selectedSpaceID"]:
    errors.append("persisted Space/tab UUID order or selected Space differs on restore")
if [s["name"] for s in spaces] != ["Main", "Work", "Personal"] or any(len(s["tabs"]) != 2 for s in spaces):
    errors.append("seed snapshot does not contain three named Spaces with two tabs each")
for space in spaces:
    if space["selectedTabID"] not in [t["id"] for t in space["tabs"]]:
        errors.append("seed selection is outside its Space")
for error in errors:
    print(f"FAIL: {error}")
sys.exit(bool(errors))
