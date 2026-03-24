#!/usr/bin/env bash
set -euo pipefail

#
# Upload a Windows 10 golden disk image to a container registry (as OCI artifact).
#
# This uses skopeo to stream the image directly to the registry without building
# a full container image locally (avoids overwhelming Docker/podman with large files).
#
# CDI auto-detects gzip-compressed disk images, so .img.gz files work as-is.
#
# Prerequisites:
#   - skopeo, jq
#   - Logged in to quay.io: skopeo login quay.io
#
# Usage:
#   ./upload-golden-image.sh [disk-image-file]
#
# Environment variables:
#   REGISTRY_IMAGE  Target registry image (default: quay.io/toschneck/kvirt-disks-windows-10-golden:latest)
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISKS_DIR="${SCRIPT_DIR}/../.disks"

REGISTRY_IMAGE="${REGISTRY_IMAGE:-quay.io/toschneck/kvirt-disks-windows-10-golden:latest}"
DISK_FILE="${1:-${DISKS_DIR}/win10-golden.img.gz}"

if [[ ! -f "$DISK_FILE" ]]; then
    echo "Error: Disk image not found: ${DISK_FILE}"
    echo "Usage: $0 [disk-image-file]"
    echo ""
    echo "Download it first with: ./download-golden-image.sh"
    exit 1
fi

echo "=== Pushing disk image to ${REGISTRY_IMAGE} ==="
echo "  Disk file: ${DISK_FILE} ($(du -h "$DISK_FILE" | cut -f1))"

# Create an OCI image layout with the disk at /disk/ (what CDI expects)
# Using skopeo + a temp OCI layout avoids loading the full image into docker/podman
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

OCI_DIR="${WORK_DIR}/oci-image"
mkdir -p "${OCI_DIR}/blobs/sha256" "${OCI_DIR}/rootfs/disk"

# Copy disk into rootfs
echo "  Preparing OCI layout..."
cp "$DISK_FILE" "${OCI_DIR}/rootfs/disk/"

# Create the OCI tar layer from rootfs
LAYER_TAR="${WORK_DIR}/layer.tar"
tar -cf "$LAYER_TAR" -C "${OCI_DIR}/rootfs" disk/

LAYER_SHA=$(sha256sum "$LAYER_TAR" | cut -d' ' -f1)
LAYER_SIZE=$(stat -f%z "$LAYER_TAR" 2>/dev/null || stat -c%s "$LAYER_TAR")
mv "$LAYER_TAR" "${OCI_DIR}/blobs/sha256/${LAYER_SHA}"

# Create OCI config
CONFIG=$(jq -n '{
  "architecture": "amd64",
  "os": "linux",
  "rootfs": { "type": "layers", "diff_ids": ["sha256:'"${LAYER_SHA}"'"] },
  "config": {}
}')
CONFIG_SHA=$(echo -n "$CONFIG" | sha256sum | cut -d' ' -f1)
CONFIG_SIZE=${#CONFIG}
echo -n "$CONFIG" > "${OCI_DIR}/blobs/sha256/${CONFIG_SHA}"

# Create OCI manifest
MANIFEST=$(jq -n '{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:'"${CONFIG_SHA}"'",
    "size": '"${CONFIG_SIZE}"'
  },
  "layers": [{
    "mediaType": "application/vnd.oci.image.layer.v1.tar",
    "digest": "sha256:'"${LAYER_SHA}"'",
    "size": '"${LAYER_SIZE}"'
  }]
}')
MANIFEST_SHA=$(echo -n "$MANIFEST" | sha256sum | cut -d' ' -f1)
MANIFEST_SIZE=${#MANIFEST}
echo -n "$MANIFEST" > "${OCI_DIR}/blobs/sha256/${MANIFEST_SHA}"

# Create OCI index
jq -n '{
  "schemaVersion": 2,
  "manifests": [{
    "mediaType": "application/vnd.oci.image.manifest.v1+json",
    "digest": "sha256:'"${MANIFEST_SHA}"'",
    "size": '"${MANIFEST_SIZE}"'
  }]
}' > "${OCI_DIR}/index.json"

echo '{"imageLayoutVersion":"1.0.0"}' > "${OCI_DIR}/oci-layout"

# Push using skopeo (streams to registry, no local daemon needed)
echo "  Pushing to registry (this may take a while for large images)..."
skopeo copy "oci:${OCI_DIR}" "docker://${REGISTRY_IMAGE}"

echo ""
echo "=== Done ==="
echo "  Pushed: ${REGISTRY_IMAGE}"
echo ""
echo "To deploy on a target cluster, apply:"
echo "  kubectl apply -f vm-from-registry-image.yaml"