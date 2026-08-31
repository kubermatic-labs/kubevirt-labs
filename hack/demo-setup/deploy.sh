#!/usr/bin/env bash
#
# Deploy / manage the tobi-demo-bastion KubeVirt VM on the demo cluster.
#
# Usage:
#   bash deploy.sh cloudinit   # (re)create the cloud-init Secret from cloudinit/bastion-user-data.sh
#   bash deploy.sh apply       # cloud-init Secret + manifest + wait for readiness + publish + print SSH
#   bash deploy.sh status      # VM/VMI/pod/PVC + pinned IP + public LB IP + endpoint health
#   bash deploy.sh endpoints   # re-point the routing cluster's Endpoints at the VM's current IP
#   bash deploy.sh destroy     # delete the VM (and its PVCs, via the dataVolumeTemplates owner refs)
#
# Requirements: kubectl on PATH, demo.env present (KUBECONFIG_KUBEV set).
# virtctl is only needed for the console/serial fallback, no longer for SSH.
#
# NOTE: This script does NOT run `netbird up` (auth is manual - see README.md).

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# shellcheck disable=SC1091
source ./demo.env

: "${KUBECONFIG_KUBEV:?KUBECONFIG_KUBEV must be set in hack/demo-setup/demo.env}"

NAMESPACE="kubermatic-virtualization"
VM_NAME="tobi-demo-bastion"
MANIFEST="bastion-vm.yaml"
CLOUDINIT_SRC="cloudinit/bastion-user-data.sh"
CLOUDINIT_SECRET="${VM_NAME}-cloudinit"
NETWORK_LS="ovn-default"
# NOTE: virt-launcher pods carry the label `vm.kubevirt.io/name` - NOT
# `kubevirt.io/domain`, which KubeVirt only propagates when the VMI template
# sets it. The PVCs carry no VM label at all, so they are selected by name.
POD_SELECTOR="vm.kubevirt.io/name=tobi-demo-bastion"

# The VM's address on ovn-default is PINNED (ovn.kubernetes.io/ip_address in the
# manifest) because the routing cluster publishes it through a selector-less
# Service whose Endpoints hard-code the address. Auto-allocation would make
# those Endpoints go stale on every recreate.
BASTION_VM_IP="${BASTION_VM_IP:-172.16.15.255}"
BASTION_SSH_USER="${BASTION_SSH_USER:-ubuntu}"
BASTION_LB_NAMESPACE="${BASTION_LB_NAMESPACE:-vm-aas-demo}"
BASTION_LB_SVC="${BASTION_LB_SVC:-bastion-vm}"

# kubectl against the KubeVirt seed (where the VM lives), namespaced.
k() { KUBECONFIG="$KUBECONFIG_KUBEV" kubectl -n "$NAMESPACE" "$@"; }
# kubectl against the KKP routing cluster (where the public LB lives).
kr() { KUBECONFIG="$KUBECONFIG_ROUTING_CLUSTER" kubectl -n "$BASTION_LB_NAMESPACE" "$@"; }

have_routing_cluster() {
  [ -n "${KUBECONFIG_ROUTING_CLUSTER:-}" ] && [ -f "${KUBECONFIG_ROUTING_CLUSTER}" ]
}

# --------------------------------------------------------------------------
# cloud-init Secret
# --------------------------------------------------------------------------
# KubeVirt caps INLINE cloudInitNoCloud.userData at 2048 bytes; our bootstrap is
# larger, so it lives in a Secret that the manifest references via secretRef.
cloudinit() {
  [ -f "$CLOUDINIT_SRC" ] || { echo "!! missing $CLOUDINIT_SRC"; exit 1; }
  bash -n "$CLOUDINIT_SRC" || { echo "!! $CLOUDINIT_SRC has a syntax error, refusing to publish"; exit 1; }

  echo ">> publishing $CLOUDINIT_SRC ($(wc -c < "$CLOUDINIT_SRC" | tr -d ' ') bytes) as secret/$CLOUDINIT_SECRET"
  KUBECONFIG="$KUBECONFIG_KUBEV" kubectl create secret generic "$CLOUDINIT_SECRET" \
    -n "$NAMESPACE" \
    --from-file="userData=$CLOUDINIT_SRC" \
    --dry-run=client -o yaml | KUBECONFIG="$KUBECONFIG_KUBEV" kubectl apply -f -
}

# --------------------------------------------------------------------------
# Publish: keep the routing cluster's manual Endpoints pointed at the VM
# --------------------------------------------------------------------------
endpoints() {
  if ! have_routing_cluster; then
    echo ">> skipping publish: KUBECONFIG_ROUTING_CLUSTER unset or missing"
    return 0
  fi

  local live_ip
  live_ip=$(k get vmi "$VM_NAME" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "")
  live_ip="${live_ip:-$BASTION_VM_IP}"

  if [ "$live_ip" != "$BASTION_VM_IP" ]; then
    echo "!! WARNING: VM IP is $live_ip but the pin says $BASTION_VM_IP."
    echo "!!          Update ovn.kubernetes.io/ip_address in $MANIFEST + BASTION_VM_IP in demo.env."
  fi

  echo ">> pointing $BASTION_LB_NAMESPACE/$BASTION_LB_SVC endpoints at $live_ip:22 (routing cluster)"
  if ! kr get svc "$BASTION_LB_SVC" >/dev/null 2>&1; then
    echo "!! svc/$BASTION_LB_SVC not found - apply routing-cluster/bastion-svc-lb.yaml first:"
    echo "   KUBECONFIG=\$KUBECONFIG_ROUTING_CLUSTER kubectl apply -f routing-cluster/bastion-svc-lb.yaml"
    return 1
  fi
  kr patch endpoints "$BASTION_LB_SVC" --type merge \
    -p "{\"subsets\":[{\"addresses\":[{\"ip\":\"$live_ip\"}],\"ports\":[{\"name\":\"ssh\",\"port\":22,\"protocol\":\"TCP\"}]}]}" >/dev/null
  echo "   endpoints: $(kr get endpoints "$BASTION_LB_SVC" -o jsonpath='{.subsets[0].addresses[0].ip}:{.subsets[0].ports[0].port}')"
}

lb_ip() {
  have_routing_cluster || { echo ""; return 0; }
  kr get svc "$BASTION_LB_SVC" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo ""
}

# --------------------------------------------------------------------------
# Lifecycle
# --------------------------------------------------------------------------
apply() {
  cloudinit

  echo ">> applying $MANIFEST in ns $NAMESPACE"
  KUBECONFIG="$KUBECONFIG_KUBEV" kubectl apply -f "$MANIFEST" -n "$NAMESPACE"

  echo ">> waiting for VM to be Ready (VMI Running + virt-launcher pod + bound PVC) ..."
  READY=""
  for i in $(seq 1 60); do
    VMI=$(k get vmi "$VM_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || echo "-")
    RUNNING_PODS=$(k get po -l "$POD_SELECTOR" --no-headers 2>/dev/null | grep -c Running || true)
    PVC_BOUND=$(k get pvc "$VM_NAME" "${VM_NAME}-data" --no-headers 2>/dev/null | grep -c Bound || true)
    if [ "$VMI" = "Running" ] && [ "$RUNNING_PODS" -ge 1 ] && [ "$PVC_BOUND" -ge 2 ]; then
      READY="yes"
      break
    fi
    echo "  ... ($i) VMI=$VMI pods=$RUNNING_PODS pvc=$PVC_BOUND/2 (Ctrl-C to tail)"
    sleep 5
  done

  if [ "$READY" != "yes" ]; then
    echo "!! VM did not become Ready in time. Aborting."
    status
    exit 1
  fi
  echo ">> VM is Ready."

  echo ">> waiting for the VMI to report its address ..."
  POD_IP=""
  for _ in $(seq 1 60); do
    POD_IP=$(k get vmi "$VM_NAME" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "")
    [ -n "$POD_IP" ] && break
    sleep 5
  done

  endpoints || true
  status
}

status() {
  echo
  echo "===== Demo Bastion VM ====="
  k get vm,vmi "$VM_NAME" -o wide 2>/dev/null || true
  k get po -l "$POD_SELECTOR" -o wide 2>/dev/null || true
  k get pvc "$VM_NAME" "${VM_NAME}-data" 2>/dev/null || true
  echo

  local ip sw lb
  ip=$(k get vmi "$VM_NAME" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "")
  sw=$(k get po -l "$POD_SELECTOR" -o jsonpath='{.items[0].metadata.annotations.ovn\.kubernetes\.io/logical_switch}' 2>/dev/null || echo "")
  lb=$(lb_ip)

  echo "VM name          : $VM_NAME"
  echo "Namespace        : $NAMESPACE"
  echo "Logical switch   : ${sw:-$NETWORK_LS} (default pod network, 172.16.0.0/16)"
  echo "VM IP (pinned)   : ${ip:-<none>}  (expected $BASTION_VM_IP)"
  echo "Cloud-init       : secret/$CLOUDINIT_SECRET  <- $CLOUDINIT_SRC"
  if [ -n "$lb" ]; then
    echo "Public IP (LB)   : $lb  <- svc $BASTION_LB_NAMESPACE/$BASTION_LB_SVC on the routing cluster"
  else
    echo "Public IP (LB)   : <unknown> (routing cluster kubeconfig unset, or LB not assigned yet)"
  fi
  if have_routing_cluster; then
    echo "LB endpoints     : $(kr get endpoints "$BASTION_LB_SVC" -o jsonpath='{.subsets[0].addresses[0].ip}:{.subsets[0].ports[0].port}' 2>/dev/null || echo '<none>')"
  fi

  echo
  echo "Connect (dedicated public IP - no virtctl tunnel):"
  echo "  ssh ${BASTION_SSH_KEY:+-i $BASTION_SSH_KEY }$BASTION_SSH_USER@${lb:-${BASTION_LB_IP:-<lb-ip>}}"
  echo "  just ssh"
  echo
  echo "Fallback if the KubeLB hop is down (socat jump pod, key stays in your agent):"
  echo "  just ssh-jump"
  echo "  # last resort, serial console (needs virtctl v1.6.5):"
  echo "  virtctl console $VM_NAME -n $NAMESPACE"
  echo
}

destroy() {
  echo ">> deleting VM $VM_NAME (PVCs follow via dataVolumeTemplates owner refs)"
  KUBECONFIG="$KUBECONFIG_KUBEV" kubectl delete -f "$MANIFEST" -n "$NAMESPACE" --ignore-not-found
  echo ">> deleting secret/$CLOUDINIT_SECRET"
  k delete secret "$CLOUDINIT_SECRET" --ignore-not-found
  echo ">> note: the routing cluster's svc/$BASTION_LB_SVC is left in place so the"
  echo "         public IP ($BASTION_LB_IP) is not lost. Run 'just publish' after recreating."
}

case "${1:-apply}" in
  cloudinit) cloudinit ;;
  apply)     apply ;;
  status)    status ;;
  endpoints) endpoints ;;
  destroy)   destroy ;;
  *) echo "unknown subcommand: ${1:-} (use cloudinit|apply|status|endpoints|destroy)"; exit 1 ;;
esac
