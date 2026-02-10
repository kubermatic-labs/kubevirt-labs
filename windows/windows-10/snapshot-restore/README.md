# Snapshot & Restore Demo for Windows 10 VM

This folder contains example manifests to create and restore KubeVirt VM snapshots for the `vm-win-10-preset` virtual machine.

Reference: https://kubevirt.io/user-guide/storage/snapshot_restore_api/

## Prerequisites

- CSI driver with `VolumeSnapshot` support and a configured `VolumeSnapshotClass`
- Kubernetes Volume Snapshot APIs served from `v1`
- Snapshot feature gate enabled in the KubeVirt CR:
  ```yaml
  apiVersion: kubevirt.io/v1
  kind: KubeVirt
  spec:
    configuration:
      developerConfiguration:
        featureGates:
          - Snapshot
  ```
- (Optional) QEMU guest agent installed in the Windows VM for application-consistent snapshots

## Demo Workflow

### 1. Create a Snapshot

```bash
kubectl apply -f 01-snapshot.yaml

# Wait until the snapshot is ready
kubectl -n vm-win-10-preset wait virtualmachinesnapshot snap-vm-win-10-preset \
  --for=condition=Ready --timeout=10m
```

The snapshot can be taken while the VM is running (online snapshot). If the QEMU guest agent is installed, the filesystem will be quiesced for consistency. Without the guest agent, a crash-consistent snapshot is created.

### 2. Restore from Snapshot

```bash
# Stop the VM first (or use targetReadinessPolicy: StopTarget to auto-stop)
virtctl stop vm-win-10-preset -n vm-win-10-preset

kubectl apply -f 02-restore.yaml

# Wait until the restore completes
kubectl -n vm-win-10-preset wait virtualmachinerestore restore-vm-win-10-preset \
  --for=condition=Ready --timeout=10m

# Start the VM again
virtctl start vm-win-10-preset -n vm-win-10-preset
```

### 3. Clean Up

```bash
# Delete the snapshot when no longer needed
kubectl -n vm-win-10-preset delete virtualmachinesnapshot snap-vm-win-10-preset

# Delete the restore object
kubectl -n vm-win-10-preset delete virtualmachinerestore restore-vm-win-10-preset
```

## Inspect Snapshot Details

```bash
# View snapshot status and included volumes
kubectl -n vm-win-10-preset get virtualmachinesnapshot snap-vm-win-10-preset -o yaml

# View the underlying snapshot content
kubectl -n vm-win-10-preset get virtualmachinesnapshotcontent -l vm.kubevirt.io/name=vm-win-10-preset
```
