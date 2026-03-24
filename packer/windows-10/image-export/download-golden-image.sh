#!/usr/bin/env bash
set -euo pipefail

#
# Download the Windows 10 golden disk image from a KubeVirt cluster.
#
# The script creates a vmexport, then checks whether external links are available.
# If not (common in clusters without Ingress/LoadBalancer for the export proxy),
# it falls back to kubectl port-forward + curl to download the image.
#
# The image is downloaded gzip-compressed to reduce transfer time.
#
# Prerequisites:
#   - kubectl, virtctl, curl
#   - Access to the source cluster via SRC_KUBECONFIG
#
# Usage:
#   export SRC_KUBECONFIG=/path/to/source-kubeconfig
#   ./download-golden-image.sh [output-file]
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISKS_DIR="${SCRIPT_DIR}/../.disks"

DATASOURCE_NAME="windows-10-golden"
DATASOURCE_NS="build-vm-win10"
EXPORT_NAME="win10-export"
OUTPUT_FILE="${1:-${DISKS_DIR}/win10-golden.img.gz}"
LOCAL_PORT="${LOCAL_PORT:-8443}"

mkdir -p "$(dirname "$OUTPUT_FILE")"

SRC_KUBECONFIG="${SRC_KUBECONFIG:?Set SRC_KUBECONFIG to the source cluster kubeconfig path}"

KC="--kubeconfig=$SRC_KUBECONFIG"

cleanup() {
    # Kill port-forward if running
    if [[ -n "${PF_PID:-}" ]]; then
        kill "$PF_PID" 2>/dev/null || true
        wait "$PF_PID" 2>/dev/null || true
    fi
    # Remove the vmexport object
    virtctl vmexport delete "$EXPORT_NAME" -n "$PVC_NS" $KC 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Resolving DataSource ${DATASOURCE_NS}/${DATASOURCE_NAME} ==="
PVC_NAME=$(kubectl $KC -n "$DATASOURCE_NS" \
    get datasource "$DATASOURCE_NAME" -o jsonpath='{.spec.source.pvc.name}')
PVC_NS=$(kubectl $KC -n "$DATASOURCE_NS" \
    get datasource "$DATASOURCE_NAME" -o jsonpath='{.spec.source.pvc.namespace}')
PVC_NS="${PVC_NS:-$DATASOURCE_NS}"

echo "  PVC: ${PVC_NS}/${PVC_NAME}"

echo ""
echo "=== Creating vmexport ==="
virtctl vmexport delete "$EXPORT_NAME" -n "$PVC_NS" $KC 2>/dev/null || true

virtctl vmexport create "$EXPORT_NAME" \
    --pvc="$PVC_NAME" \
    -n "$PVC_NS" \
    $KC

echo "  Waiting for export to be ready..."
kubectl $KC -n "$PVC_NS" \
    wait vmexport "$EXPORT_NAME" --for=condition=Ready --timeout=300s

echo ""
echo "=== Checking for external links ==="
EXTERNAL_URL=$(kubectl $KC -n "$PVC_NS" \
    get vmexport "$EXPORT_NAME" \
    -o jsonpath='{.status.links.external.volumes[0].formats[?(@.format=="gzip")].url}' 2>/dev/null || true)

if [[ -n "$EXTERNAL_URL" ]]; then
    echo "  External link available, downloading via virtctl..."
    virtctl vmexport download "$EXPORT_NAME" \
        --output="$OUTPUT_FILE" \
        -n "$PVC_NS" \
        $KC
else
    echo "  No external links available, falling back to port-forward..."

    INTERNAL_URL=$(kubectl $KC -n "$PVC_NS" \
        get vmexport "$EXPORT_NAME" \
        -o jsonpath='{.status.links.internal.volumes[0].formats[?(@.format=="gzip")].url}')

    # Extract the path portion from the internal URL
    URL_PATH=$(echo "$INTERNAL_URL" | sed 's|https://[^/]*||')

    TOKEN=$(kubectl $KC -n "$PVC_NS" \
        get secret "secret-${EXPORT_NAME}" -o jsonpath='{.data.token}' | base64 -d)

    echo "  Starting port-forward on localhost:${LOCAL_PORT}..."
    kubectl $KC -n "$PVC_NS" \
        port-forward "svc/virt-export-${EXPORT_NAME}" "${LOCAL_PORT}:443" &
    PF_PID=$!
    sleep 2

    # Verify port-forward is running
    if ! kill -0 "$PF_PID" 2>/dev/null; then
        echo "  Error: port-forward failed to start"
        exit 1
    fi

    echo "  Downloading ${URL_PATH} ..."
    curl -k --progress-bar \
        -H "x-kubevirt-export-token: ${TOKEN}" \
        "https://localhost:${LOCAL_PORT}${URL_PATH}" \
        -o "$OUTPUT_FILE"

    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
    unset PF_PID
fi

echo ""
echo "=== Done ==="
echo "  Downloaded: ${OUTPUT_FILE} ($(du -h "$OUTPUT_FILE" | cut -f1))"
echo ""
echo "Next step: upload to registry with ./upload-golden-image.sh ${OUTPUT_FILE}"