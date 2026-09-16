#!/usr/bin/env python3
"""Repoint an APIExport's spec.resources at the APIResourceSchemas the agent just published.

The api-syncagent creates a new APIResourceSchema whenever a published CRD's schema
changes, but it deliberately never rewrites APIExport.spec.resources - rebinding is the
service owner's decision, since consumers are bound to the old shape. The consequence is
that after an RGD schema change KDP keeps serving the previous shape with no error
anywhere; `kubectl explain` in the workspace simply shows stale fields.

Each PublishedResource records the schema it published in
`status.resourceSchemaName`, which is authoritative - no guessing by timestamp.

Usage:
  apiexport-schemas.py <apiexport.json> <publishedresources.json>

Prints an RFC 6902 patch on stdout, or nothing if already current.
"""
import json
import sys


def main():
    with open(sys.argv[1]) as fh:
        apiexport = json.load(fh)
    with open(sys.argv[2]) as fh:
        published = json.load(fh)

    # An APIResourceSchema is named "<hash>.<plural>.<group>"; index by (plural, group).
    current = {}
    for item in published.get("items", []):
        name = item.get("status", {}).get("resourceSchemaName")
        if not name:
            continue
        parts = name.split(".", 1)
        if len(parts) != 2:
            continue
        resource, group = parts[1].split(".", 1)
        current[(resource, group)] = name

    resources = apiexport["spec"]["resources"]
    changed = []
    for entry in resources:
        key = (entry["name"], entry["group"])
        want = current.get(key)
        if want and want != entry.get("schema"):
            changed.append(f"{entry['name']}.{entry['group']}: {entry.get('schema')} -> {want}")
            entry["schema"] = want

    if not changed:
        print("", end="")
        sys.stderr.write("APIExport already points at the published schemas\n")
        return

    for line in changed:
        sys.stderr.write(f"  {line}\n")
    print(json.dumps([{"op": "replace", "path": "/spec/resources", "value": resources}]))


if __name__ == "__main__":
    main()
