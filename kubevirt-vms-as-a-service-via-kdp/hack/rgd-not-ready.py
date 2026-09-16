#!/usr/bin/env python3
"""Report kro ResourceGraphDefinitions whose Ready condition is not True.

kro's `status.state` and `conditions[Ready]` disagree: a CRD update that would drop a
property is refused with "breaking changes detected" and leaves Ready=False, while state
stays "Active". Anything that gates on state therefore reports success on a no-op.

Reads `kubectl get resourcegraphdefinition -o json` on stdin.

  --names-only    print just the RGD names, one per line (for shell loops)
  --breaking      only report RGDs blocked on a breaking schema change
"""
import json
import sys


def main():
    args = set(sys.argv[1:])
    names_only = "--names-only" in args
    breaking_only = "--breaking" in args

    items = json.load(sys.stdin).get("items", [])
    for item in items:
        name = item["metadata"]["name"]
        for cond in item.get("status", {}).get("conditions", []):
            if cond.get("type") != "Ready" or cond.get("status") == "True":
                continue
            message = cond.get("message", "")
            if breaking_only and "breaking changes" not in message:
                continue
            print(name if names_only else f"  {name}: {message}")


if __name__ == "__main__":
    main()
