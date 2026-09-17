#!/usr/bin/env bash
set -euo pipefail

# Applies infra/rbac.yaml to the infra (KubeVirt) cluster and mints a kubeconfig
# from the ServiceAccount's long-lived token. That kubeconfig is what KubeOne
# consumes as KUBEVIRT_KUBECONFIG - for provisioning the VMs, and as the
# credential it hands to the CCM, CSI driver and machine-controller inside the
# new cluster.
#
# Usage:
#   KUBECONFIG=<infra-cluster-kubeconfig> ./sa-kubeconfig.sh \
#     --namespace kubeone-demo \
#     --name kubeone-infra \
#     --output kubeone-infra-kubeconfig

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/rbac.yaml"

SA_NAME="kubeone-infra"
NAMESPACE="kubeone-demo"
OUTPUT="${SCRIPT_DIR}/kubeone-infra-kubeconfig"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --name       NAME        ServiceAccount / Role / RoleBinding name (default: ${SA_NAME})
  --namespace  NAMESPACE   Infra cluster namespace (default: ${NAMESPACE})
  --output     FILE        Output kubeconfig path (default: ${OUTPUT})
  -h, --help               Show this help

Environment:
  KUBECONFIG               Points at the INFRA cluster. Required.
EOF
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)       SA_NAME="$2";    shift 2 ;;
    --namespace)  NAMESPACE="$2";  shift 2 ;;
    --output)     OUTPUT="$2";     shift 2 ;;
    -h|--help)    usage 0 ;;
    *)            echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "ERROR: KUBECONFIG is not set - it must point at the infra cluster." >&2
  exit 1
fi

SECRET_NAME="${SA_NAME}-token"

echo "==> ServiceAccount ${NAMESPACE}/${SA_NAME} on $(kubectl config current-context)"

# --- 1. Namespace --------------------------------------------------------
kubectl get namespace "$NAMESPACE" &>/dev/null || kubectl create namespace "$NAMESPACE"

# --- 2. RBAC -------------------------------------------------------------
echo "==> Applying RBAC"
sed -e "s/__SA_NAME__/${SA_NAME}/g" \
    -e "s/__NAMESPACE__/${NAMESPACE}/g" \
    "$TEMPLATE" | kubectl apply -f -

# --- 3. Wait for the token ----------------------------------------------
echo -n "==> Waiting for token in secret ${SECRET_NAME}"
TOKEN=""
for _ in $(seq 1 30); do
  TOKEN=$(kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" -o jsonpath='{.data.token}' 2>/dev/null || true)
  [[ -n "$TOKEN" ]] && break
  echo -n "."
  sleep 2
done
echo

if [[ -z "$TOKEN" ]]; then
  echo "ERROR: timed out waiting for a token in secret '${SECRET_NAME}'." >&2
  exit 1
fi

# --- 4. Assemble the kubeconfig -----------------------------------------
SA_TOKEN=$(echo "$TOKEN" | base64 -d 2>/dev/null || echo "$TOKEN" | base64 -D)
CA_DATA=$(kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" -o jsonpath='{.data.ca\.crt}')
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')

mkdir -p "$(dirname "$OUTPUT")"
cat > "$OUTPUT" <<EOF
apiVersion: v1
kind: Config
preferences: {}
current-context: ${SA_NAME}@${CLUSTER_NAME}
clusters:
- cluster:
    certificate-authority-data: ${CA_DATA}
    server: ${SERVER}
  name: ${CLUSTER_NAME}
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    namespace: ${NAMESPACE}
    user: ${SA_NAME}
  name: ${SA_NAME}@${CLUSTER_NAME}
users:
- name: ${SA_NAME}
  user:
    token: ${SA_TOKEN}
EOF
chmod 600 "$OUTPUT"

echo "==> Wrote ${OUTPUT} (server ${SERVER})"
echo "    Test: KUBECONFIG=${OUTPUT} kubectl get vm -n ${NAMESPACE}"
