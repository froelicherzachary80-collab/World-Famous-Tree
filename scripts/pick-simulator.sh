#!/usr/bin/env bash
# Prints an xcodebuild -destination value for the newest available iPhone simulator.
set -euo pipefail
xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)["devices"]
best = None
for runtime, devs in data.items():
    if "iOS" not in runtime:
        continue
    ver = tuple(int(x) for x in runtime.rsplit("iOS-", 1)[-1].split("-"))
    for d in devs:
        if d["name"].startswith("iPhone") and (best is None or ver > best[0]):
            best = (ver, d["udid"])
if not best:
    sys.exit("no iPhone simulator available")
print(f"id={best[1]}")
'
