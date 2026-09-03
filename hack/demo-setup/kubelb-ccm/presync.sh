#!/usr/bin/env bash
#
# presync hook for the KubeLB CCM release (see helmfile.yaml.gotmpl).
#
# Idempotent - safe to re-run on every `helmfile apply`:
#   1. namespace/kubelb
#   2. the CRDs shipped in the chart's crds/ dir. Load-bearing, not tidiness:
#      the CCM registers its SyncSecretReconciler against the tenant cluster
#      unconditionally (cmd/ccm/main.go - only SecretConversionReconciler sits
#      behind enableSecretSynchronizer), so with syncsecrets.kubelb.k8c.io
#      missing the manager's cache never starts and the pod crash-loops.
#      Helm v4 does create missing CRDs on `upgrade --install`, but it never
#      updates one that already exists, and Helm v3 does neither on upgrade.
#   3. secret/kubelb-cluster - the tenant kubeconfig for the KubeLB manager,
#      under key `kubelb`. Built from a file on disk rather than a committed
#      manifest: the token is a live credential and this repo is public. The fog
#      environment solves the same problem with sops, which is not set up here.
#   4. a liveness check on that token, so a silent 401 shows up now instead of
#      as a CCM CrashLoopBackOff ten minutes later.
#
# Usage: bash presync.sh [chart-ref] [chart-version]
#
# Both are passed in by helmfile.yaml.gotmpl from the same variables the release
# uses, so the hook and the release can never point at different charts.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# demo.env lives one level up and carries the kubeconfig paths (gitignored).
# shellcheck disable=SC1091
[ -f ../demo.env ] && source ../demo.env

CHART="${1:-${KUBELB_CHART:-oci://quay.io/kubermatic/helm-charts/kubelb-ccm}}"
VERSION="${2:-${KUBELB_VERSION:-v1.5.0}}"
NAMESPACE="kubelb"
SECRET="kubelb-cluster"
TENANT="${KUBELB_TENANT:-kubev-vm-ccm}"
CCM_KUBECONFIG="${KUBELB_CCM_KUBECONFIG:-${PWD}/kubelb-kubev-vm-ccm.kubeconfig}"

: "${KUBECONFIG_KUBEV:?KUBECONFIG_KUBEV must be set in hack/demo-setup/demo.env}"

# kubectl against the KubeVirt demo cluster (the tenant side).
k() { KUBECONFIG="$KUBECONFIG_KUBEV" kubectl "$@"; }
# kubectl against the KubeLB manager, as the tenant service account.
m() { kubectl --kubeconfig="$CCM_KUBECONFIG" "$@"; }

# ---------------------------------------------------------------------------
# 1. namespace
# ---------------------------------------------------------------------------
k create namespace "$NAMESPACE" --dry-run=client -o yaml | k apply -f - >/dev/null
echo ">> namespace/${NAMESPACE} ready"

# ---------------------------------------------------------------------------
# 2. CRDs from the chart
# ---------------------------------------------------------------------------
crd_dir="$(mktemp -d)"
trap 'rm -rf "$crd_dir"' EXIT

echo ">> pulling ${CHART}:${VERSION} for its crds/"
helm pull "$CHART" --version "$VERSION" --untardir "$crd_dir" --untar >/dev/null
k apply -f "${crd_dir}/$(basename "$CHART")/crds/"

# ---------------------------------------------------------------------------
# 3. manager kubeconfig -> secret/kubelb-cluster
# ---------------------------------------------------------------------------
if [ ! -f "$CCM_KUBECONFIG" ]; then
  echo "!! missing tenant kubeconfig: $CCM_KUBECONFIG"
  echo "   Fetch it from the KubeLB manager (needs admin there, not this token):"
  echo "     kubectl -n tenant-${TENANT} get secret kubelb-ccm-kubeconfig \\"
  echo "       -o go-template='{{ index .data \"kubelb\" }}' | base64 -d > $CCM_KUBECONFIG"
  exit 1
fi

echo ">> refreshing secret/${SECRET} in ns/${NAMESPACE} from $(basename "$CCM_KUBECONFIG")"
k -n "$NAMESPACE" create secret generic "$SECRET" \
  --from-file="kubelb=${CCM_KUBECONFIG}" \
  --dry-run=client -o yaml | k apply -f - >/dev/null

# ---------------------------------------------------------------------------
# 4. is the token still good?
# ---------------------------------------------------------------------------
if ! who="$(m auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null)"; then
  echo "!! the tenant kubeconfig does not authenticate against the KubeLB manager"
  echo "   (expired or revoked token - re-fetch it, see README.md)"
  exit 1
fi
echo ">> KubeLB manager reachable as ${who}"

# The SA is namespaced to tenant-<name>; a mismatch against values.yaml
# tenantName would leave the CCM writing LoadBalancers nobody reconciles.
sa_ns="${who#system:serviceaccount:}"; sa_ns="${sa_ns%%:*}"
if [ "$sa_ns" != "tenant-${TENANT}" ]; then
  echo "!! kubeconfig is scoped to ${sa_ns} but KUBELB_TENANT is ${TENANT}"
  echo "   -> fix KUBELB_TENANT in demo.env and kubelb.tenantName in values.yaml"
  exit 1
fi
