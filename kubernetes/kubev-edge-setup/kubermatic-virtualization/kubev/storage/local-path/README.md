# Local Disk Storage for KubeVirt

Lightweight node-local storage for a single edge device using
[`rancher/local-path-provisioner`](https://github.com/rancher/local-path-provisioner)
(v0.0.37).

A single controller `Deployment` dynamically provisions each volume as a
`hostPath` on the node's local disk (under `/opt/local-path-provisioner`). No
replica engines, no distributed data plane, no NFS share manager — the smallest
possible footprint. Perfect for a one-box KubeV edge device.

**Reference:** https://github.com/rancher/local-path-provisioner

## What it provides

| StorageClass | Provisioner | Default | Volume Mode | Access Mode | Use Case |
|--------------|-------------|---------|-------------|-------------|----------|
| `kubev-main` | `rancher.io/local-path` | Yes | Filesystem | RWO | General / runtime workloads |
| `kubev-vms`  | `rancher.io/local-path` | No  | Filesystem | RWO | KubeVirt VMs (CDI default-virt-class) |

Both classes use `volumeBindingMode: WaitForFirstConsumer` — volumes bind and
are created on the node as soon as a pod/VM consumes them.

## Quick Start

Cluster config stays at `storage: none` (`kubev/kubev.yaml`). Run this helmfile
**from the `kubev/` directory** (same working directory as the Rook Ceph manage flow):

```bash
cd kubernetes/kubev-edge-setup/kubermatic-virtualization/kubev

# Review changes first
helmfile diff

# Deploy the provisioner + apply the StorageClasses + reuse the CDI config
helmfile sync
```

The `postsync` hook automatically applies `storage/local-path/storageclass.yaml`,
reuses the existing `storage/cdi-config.yaml` (its
`scratchSpaceStorageClass: kubev-vms` now resolves to the local-path class), and
pins the CDI StorageProfiles via `storage/local-path/storageprofile.yaml`.

### Why the StorageProfiles must be pinned

CDI keeps one `StorageProfile` per StorageClass and uses it to fill in the
`volumeMode` / `accessModes` a caller left unset. **local-path is not in CDI's
table of known provisioners**, so both profiles come up with an empty
`claimPropertySets` - CDI has nothing to resolve from, and callers are free to
ask for `Block`, which local-path refuses. The disk PVC then hangs `Pending`
forever and the VM never starts. The KubeV dashboard has a warning for exactly
this case ("*Storage class X has no StorageProfile capabilities - Automatic
access/volume modes may not resolve*").

`storageprofile.yaml` pins both classes to `Filesystem` + `ReadWriteOnce`, which
is the single control point for every consumer:

| Consumer | How it picks a volume mode |
|----------|----------------------------|
| KubeV dashboard / kubevirt-manager | "Automatic" resolves from the profile. An **explicit** `Block` choice in the UI still fails - leave it on Automatic. |
| KubeOne / machine-controller | The KubeVirt provider has **no** `volumeMode` field (only `storageClassName` + `storageAccessType`) and never sets it, so CDI resolves it from the profile. It also reads the profile to pick an access mode when `storageAccessType` is empty, and would choose RWX if one were advertised. |
| Any `DataVolume` with `spec.storage` | Rendered from the profile by CDI. |

Verify the override took (status must mirror spec):

```bash
kubectl get storageprofile kubev-vms -o jsonpath='{.status.claimPropertySets}{"\n"}'
# [{"accessModes":["ReadWriteOnce"],"volumeMode":"Filesystem"}]
```

### Verify

```bash
kubectl -n local-path-storage get deploy/local-path-provisioner   # 1/1 Running (replicas 1)
kubectl get sc kubev-main kubev-vms                               # both present, kubev-main default
```

### Smoke test (demo Ubuntu VM)

```bash
kubectl apply -f ../../../../linux/00_kubevirt-vm-ubuntu-kkp-like.yaml
watch kubectl get vm,vmi,po,pvc
# Confirm the VM boots and its disk PVC is Bound on storageClass kubev-vms
```

## Known Trade-offs (single edge device)

- **No `volumeMode: Block`.** `local-path` cannot provision Block volumes and
  rejects them (`"...does not support block volume provisioning"`). The
  `kubev-vms`/`kubev-main` classes here are explicitly Filesystem. **Not suitable
  for the Windows golden-image pipeline** (`packer/windows-10`, `upload-to-kubev.sh`),
  which requires Block + RWX (`kubev-vms`). Those flows need the
  **Longhorn / Rook Ceph** classes instead.
- **No `ReadWriteMany` / no live migration.** hostPath is node-local and RWO-only.
  RWX is not merely unsupported, it is rejected (`NodePath only supports
  ReadWriteOnce and ReadWriteOncePod (1.22+) access modes`) and the claim never
  binds. Irrelevant on a single device, but any future multi-node /
  live-migration setup must use Longhorn or Rook Ceph.
- **No volume expansion, no size enforcement.** `local-path` does not honor size
  limits or expansion requests. Capacity is bounded by the node's disk.
- **Data lives on the node disk only.** No replication or backup. If the node dies
  or its disk fails, data is gone. Suitable for lab / edge; use distributed storage
  for anything that needs durability.

## Switching back to Rook Ceph / Longhorn

These are alternative helmfiles you run instead of this one — `kubev.yaml` stays
at `storage: none` regardless:

```bash
# Rook Ceph
helmfile -f kubev/helmfile.yaml sync

# Local-path (this option)
helmfile -f kubev/storage/local-path/helmfile.yaml sync
```

## Uninstallation

```bash
# Remove the StorageClasses and CDI config (optional, but clean)
kubectl delete -f storage/local-path/storageclass.yaml
kubectl delete -f storage/cdi-config.yaml
# StorageProfiles are owned by CDI - clear the override instead of deleting them
for sc in kubev-vms kubev-main; do
  kubectl patch storageprofile "$sc" --type=merge -p '{"spec":{}}'
done

# Remove the provisioner (note: this does NOT delete existing PV data)
helmfile destroy

# Purge hostPath data on the node (run as root on the device)
rm -rf /opt/local-path-provisioner
```

> Before removal, delete any PVCs so their PVs are reclaimed by
> `local-path` (`reclaimPolicy: Delete`).

## Alternate: plain manifest install (fallback)

If git-based chart fetching fails in your environment, the official upstream
manifest can be applied directly (same controller, no helm):

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml
kubectl apply -f storage/local-path/storageclass.yaml
kubectl apply -f storage/cdi-config.yaml
```
