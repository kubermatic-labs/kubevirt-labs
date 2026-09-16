#!/usr/bin/env python3
"""Normalise a ui-config ConfigMap from the KDP dashboard into a committable manifest.

Strips cluster-assigned fields (uid, resourceVersion, kcp.io/cluster, managedFields) but
keeps the ui-generator-schema-hash annotation, which the dashboard compares against the
live CRD schema. Invoked by `just kdp-ui-export`.
"""
import json
import sys

KEEP_ANNOTATIONS = {
    "internal.kdp.k8c.io/ui-generator-schema-hash",
    "internal.kdp.k8c.io/ui-generator-version",
}

HEADER = """# Exported from the KDP UI builder with `just kdp-ui-export`, applied with `just kdp-ui`.
# The ui-generator-schema-hash annotation is load-bearing: the dashboard compares it
# against the live CRD schema and silently falls back to the default schema-derived
# view when it does not match. Re-export after any RGD schema change.
---"""


def emit(obj, indent=0):
    pad = "  " * indent
    lines = []
    for key, value in obj.items():
        if isinstance(value, dict):
            if not value:
                lines.append(f"{pad}{key}: {{}}")
            else:
                lines.append(f"{pad}{key}:")
                lines.append(emit(value, indent + 1))
        elif isinstance(value, str) and "\n" in value:
            lines.append(f"{pad}{key}: |-")
            lines += [f"{pad}  {line}" for line in value.split("\n")]
        else:
            lines.append(f"{pad}{key}: {json.dumps(value)}")
    return "\n".join(lines)


def main():
    src = json.load(sys.stdin)
    meta = src["metadata"]
    out = {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": meta["name"],
            "namespace": "default",
            "labels": meta.get("labels", {}),
            "annotations": {
                k: v for k, v in meta.get("annotations", {}).items() if k in KEEP_ANNOTATIONS
            },
        },
        "data": src["data"],
    }
    with open(sys.argv[1], "w") as fh:
        fh.write(HEADER + "\n" + emit(out) + "\n")


if __name__ == "__main__":
    main()
