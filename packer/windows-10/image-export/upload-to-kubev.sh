#!/usr/bin/env bash
set -euo pipefail

#
# Upload a Windows 10 golden disk image directly to a KubeVirt cluster
# using virtctl image-upload. This bypasses the container registry entirely
# and pushes the disk file straight to CDI's upload proxy.
#
# If the upload proxy isn't externally exposed (common), the script
# automatically sets up a kubectl port-forward to reach it.
#
# Prerequisites:
#   - kubectl, virtctl, curl
#   - Access to the target cluster via DST_KUBECONFIG
#
# Usage:
#   export DST_KUBECONFIG=/path/to/target-kubeconfig
#   ./upload-to-kubev.sh [disk-image-file]
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISKS_DIR="${SCRIPT_DIR}/../.disks"

DATASOURCE_NAME="windows-10-golden"
TARGET_NS="${TARGET_NS:-win10-golden}"
DISK_SIZE="${DISK_SIZE:-50Gi}"
DISK_FILE="${1:-${DISKS_DIR}/win10-golden.img.gz}"
STORAGE_CLASS="${TARGET_STORAGE_CLASS:-}"
ACCESS_MODE="${ACCESS_MODE:-ReadWriteMany}"
LOCAL_PORT="${LOCAL_PORT:-18443}"

DST_KUBECONFIG="${DST_KUBECONFIG:?Set DST_KUBECONFIG to the target cluster kubeconfig path}"

KC="--kubeconfig=$DST_KUBECONFIG"

cleanup() {
    if [[ -n "${PF_PID:-}" ]]; then
        kill "$PF_PID" 2>/dev/null || true
        wait "$PF_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [[ ! -f "$DISK_FILE" ]]; then
    echo "Error: Disk image not found: ${DISK_FILE}"
    echo "Usage: $0 [disk-image-file]"
    echo ""
    echo "Download it first with: ./download-golden-image.sh"
    exit 1
fi

echo "=== Uploading disk image directly to cluster ==="
echo "  Disk file:  ${DISK_FILE} ($(du -h "$DISK_FILE" | cut -f1))"
echo "  Target:     ${TARGET_NS}/${DATASOURCE_NAME}"
echo "  Kubeconfig: ${DST_KUBECONFIG}"
echo ""

# Create namespace
kubectl $KC create ns "$TARGET_NS" 2>/dev/null || true

# Detect CDI upload proxy namespace
CDI_NS=$(kubectl $KC get svc -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' \
    | grep 'cdi-uploadproxy' | head -1 | cut -f1)

if [[ -z "$CDI_NS" ]]; then
    echo "Error: cdi-uploadproxy service not found on the target cluster"
    exit 1
fi

echo "  CDI upload proxy found in namespace: ${CDI_NS}"

# Check if upload proxy has an external URL
UPLOAD_PROXY_EXTERNAL=$(kubectl $KC -n "$CDI_NS" get svc cdi-uploadproxy \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

UPLOAD_PROXY_URL=""
if [[ -n "$UPLOAD_PROXY_EXTERNAL" ]]; then
    UPLOAD_PROXY_URL="https://${UPLOAD_PROXY_EXTERNAL}:443"
    echo "  Using external upload proxy: ${UPLOAD_PROXY_URL}"
else
    echo "  No external upload proxy, setting up port-forward..."
    kubectl $KC -n "$CDI_NS" port-forward svc/cdi-uploadproxy "${LOCAL_PORT}:443" &
    PF_PID=$!
    sleep 2

    if ! kill -0 "$PF_PID" 2>/dev/null; then
        echo "  Error: port-forward failed to start"
        exit 1
    fi

    UPLOAD_PROXY_URL="https://localhost:${LOCAL_PORT}"
    echo "  Port-forward active on ${UPLOAD_PROXY_URL}"
fi

echo ""

# Clean up any leftover DV from a previous failed attempt
kubectl $KC -n "$TARGET_NS" delete dv "$DATASOURCE_NAME" --ignore-not-found 2>/dev/null
kubectl $KC -n "$TARGET_NS" delete pvc "$DATASOURCE_NAME" --ignore-not-found 2>/dev/null
sleep 2

# Build virtctl image-upload command
UPLOAD_CMD=(
    virtctl image-upload dv "$DATASOURCE_NAME"
    --size="$DISK_SIZE"
    --image-path="$DISK_FILE"
    --access-mode="$ACCESS_MODE"
    --namespace="$TARGET_NS"
    --uploadproxy-url="$UPLOAD_PROXY_URL"
    --force-bind
    --insecure
    $KC
)

if [[ -n "$STORAGE_CLASS" ]]; then
    UPLOAD_CMD+=(--storage-class="$STORAGE_CLASS")
fi

echo "  Running: ${UPLOAD_CMD[*]}"
echo ""

"${UPLOAD_CMD[@]}"

# Clean up port-forward
if [[ -n "${PF_PID:-}" ]]; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
    unset PF_PID
fi

echo ""
echo "=== Creating DataSource ==="
cat <<EOF | kubectl $KC apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataSource
metadata:
  name: ${DATASOURCE_NAME}
  namespace: ${TARGET_NS}
spec:
  source:
    pvc:
      name: ${DATASOURCE_NAME}
      namespace: ${TARGET_NS}
EOF

echo ""
echo "=== Done ==="
echo "  DataVolume: ${TARGET_NS}/${DATASOURCE_NAME}"
echo "  DataSource: ${TARGET_NS}/${DATASOURCE_NAME}"
echo ""
echo "Deploy a VM with:"
echo "  kubectl $KC apply -f $(dirname "$0")/vm-from-upload.yaml"