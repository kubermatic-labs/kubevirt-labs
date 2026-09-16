# kubev demo cluster: Longhorn is over-subscribed by design (3 replicas on 2 nodes)

> **Filed as [kubermatic/demo-envs#250][issue]** on 2026-09-16.
>
> [issue]: https://github.com/kubermatic/demo-envs/issues/250
>
> This file stays the local source of truth for the report. If you update the issue, update this
> file too, and vice versa.
>
> Written from outside: I have kubeconfig access to the cluster but only read access to
> `kubermatic/demo-envs`, so everything below is a suggestion for someone who can apply it. All
> proposed changes stay within the **existing two workers and their existing disks** - no new
> hardware.
>
> Labels still need to be applied by someone with triage rights on that repo: `kind/bug`. It could
> not be set at filing time - the GitHub API rejected `AddLabelsToLabelable` for `toschneck`, who
> can open issues there but not label them. (Existing issues in that repo carry no labels either.)

## Summary

The `kubev` demo cluster asks Longhorn for **three replicas of every volume on a two-node
cluster**. That cannot fit: 290.5G of provisioned volumes needs 871.5G of replica space against
655.2G of usable disk. It only appears to work because `storage-over-provisioning-percentage` was
raised to 200 in August to unblock CDI imports, which masks the shortfall rather than removing it.

Volumes are thin-provisioned (290.5G provisioned, 126.6G actually written), so the cluster runs
fine until real usage grows into the gap. Then a worker crosses kubelet's `nodefs.available<10%`
threshold and evicts - and because `/var/lib/longhorn` shares the root filesystem with kubelet's
ephemeral-storage, a full Longhorn is indistinguishable from a full node.

The eviction is not contained. The KubeVirt control plane (`kubev-api-server`,
`kubev-controller-manager`, `kubev-dashboard`) runs **BestEffort with no `priorityClassName`**, so
it is at the *front* of kubelet's eviction queue. On 2026-09-03 that cascade took out the
cluster's custom kube-ovn VPCs, their subnets and their `VpcEgressGateway`s.

Two independent problems, both fixable with what is already there:

1. **Capacity** - replica count 3 on a 2-node cluster is arithmetically impossible. Set it to 2.
2. **Blast radius** - the control plane is unprotected against eviction. Give it a priority class.

## Environment

| Item                    | Value                                                            |
| ----------------------- | ---------------------------------------------------------------- |
| Repository              | `kubermatic/demo-envs`                                           |
| Cluster                 | `kubev-cluster` (demo-envs-dc-kubevirt)                          |
| Workers                 | `kubev-demo-env-wk-1`, `kubev-demo-env-wk-2` (2 nodes)           |
| Kubernetes              | v1.34.7                                                          |
| Longhorn                | chart 1.9.1, Helm release `longhorn`, **no values file in repo** |
| Longhorn disk path      | `/var/lib/longhorn/` (shares root fs with kubelet ephemeral)     |
| StorageClass            | `kubev-vms` -> `kubev/manifests/storageclasses.yaml`             |
| Longhorn settings       | `kubev/manifests/longhorn-settings.yaml` (**untracked locally**) |
| KubeVirt chart          | `kubeone/charts/kubevirt` + `helm-values/kubevirt.yaml`          |
| First observed          | 2026-09-03                                                       |
| Recurred                | wk-1 before 2026-09-11, wk-2 before 2026-09-13                   |
| State at writing        | 2026-09-16, quiet but still over-subscribed                      |
| Reporter                | Tobias Schneck <tobias.schneck@kubermatic.com>                   |

## Impact

On 2026-09-03 `kubev-demo-env-wk-2` went `DiskPressure=True` at 08:33:38Z. What followed:

- `kube-multus-ds` evicted (`The node had condition: [DiskPressure]`)
- `kubev-api-server`, `kubev-controller-manager`, `kubev-dashboard`, `kubev-vms` restarted
- **both custom kube-ovn VPCs, their subnets and both `VpcEgressGateway`s were gone**
- VMs in those VPCs shut down; `win10-demo` left paused on `IOerror ... volume: rootdisk`
- Longhorn volumes degraded; attaches failing with
  `data engine image longhornio/longhorn-engine:v1.9.1 is not deployed on ... the node`

The kube-ovn objects were recreated on 2026-09-04, but any demo running at that moment is lost.
This is the failure mode that matters: a storage problem silently deletes the kube-ovn networking
the running demos depend on.

An earlier episode on 2026-09-04 showed the same root cause hitting CDI instead -
`cdi-upload-server` gets evicted mid-stream, the DataVolume freezes, and reports the red-herring
`snappy: corrupt input` / `ImagePullFailed`. CDI never retries an evicted upload server.

## Root cause 1: three replicas cannot fit on two nodes

Longhorn reserves 30% of each disk for the root filesystem, so usable space is well under raw:

| Node | Raw     | Reserved (30%) | Usable  | Scheduled | % of usable |
| ---- | ------- | -------------- | ------- | --------- | ----------- |
| wk-1 | 468.0G  | 140.4G         | 327.6G  | 560.1G    | **171%**    |
| wk-2 | 468.0G  | 140.4G         | 327.6G  | 311.4G    | 95%         |

The arithmetic, against the 9 volumes that exist today:

| Replica count | Space needed | Usable (2 x 327.6G) | Result                          |
| ------------- | ------------ | ------------------- | ------------------------------- |
| 3 (current)   | 871.5G       | 655.2G              | **over by 216.3G - never fits** |
| 2 (proposed)  | 581.0G       | 655.2G              | fits, 74.2G headroom            |

With `replica-soft-anti-affinity=true` a third replica does not gain redundancy on a 2-node
cluster - it just places two copies on the same node. It costs a full extra copy of every volume
and buys nothing.

The reason this has not hard-failed yet is thin provisioning: **290.5G provisioned, 126.6G actually
written**. The 164G gap is the runway before the next eviction.

`storage-minimal-available-percentage=25` stops Longhorn scheduling *new* replicas, but nothing
stops *existing* sparse volumes from growing into the window between that and kubelet's
`nodefs.available<10%`. That window is the bug.

### The replica count is pinned in three places

Changing only the global setting does nothing for VM disks, because they all come from the
`kubev-vms` StorageClass:

| Where                    | Field                         | Current   |
| ------------------------ | ----------------------------- | --------- |
| global Longhorn setting  | `default-replica-count`       | 3         |
| `kubev-vms` StorageClass | `parameters.numberOfReplicas` | 3         |
| existing volumes         | `spec.numberOfReplicas`       | 3 (all 9) |

The `vm-images/vm-image-data` PVC uses the plain `longhorn` StorageClass instead, so it picks up
the global setting - which is why both knobs matter, not just the StorageClass.

## Root cause 2: the KubeVirt control plane is first in the eviction queue

kubelet ranks eviction victims by QoS class, then by priority. Current state:

| Workload                   | priorityClassName      | QoS        | Eviction risk |
| -------------------------- | ---------------------- | ---------- | ------------- |
| `kubev-api-server`         | *none*                 | BestEffort | **first out** |
| `kubev-controller-manager` | *none*                 | BestEffort | **first out** |
| `kubev-dashboard`          | *none*                 | BestEffort | **first out** |
| `kubev-vms`                | *none*                 | Burstable  | early         |
| `virt-launcher-*` (VMs)    | *none*                 | Burstable  | early         |
| `kube-multus-ds`           | *none*                 | -          | evicted 09-03 |
| `longhorn-manager`         | `system-node-critical` | -          | protected     |

Longhorn protects itself. The virtualization stack that the demos actually depend on does not.
That asymmetry is why a disk problem turns into deleted VPCs instead of a slow volume.

## Suggested changes

Ordered by impact. Every one works with the current two nodes and their current disks.

### 1. Drop replicas from 3 to 2, in all three places

This is the fix that makes the arithmetic work. Frees roughly 290G of scheduled capacity.

**`kubev/manifests/storageclasses.yaml`**

```diff
-  numberOfReplicas: "3"
+  # 2 workers: a 3rd replica cannot land on a distinct node, so it only doubles
+  # disk cost on one of them. 2 replicas is strictly better here for both
+  # availability and space.
+  numberOfReplicas: "2"
```

Note this needs the StorageClass to be **recreated**, not patched - `parameters` is immutable.
Existing PVs keep their own replica count either way, so they need the patch in the next step.

**`kubev/manifests/longhorn-settings.yaml`** - add the global default so non-`kubev-vms` volumes
(such as `vm-images/vm-image-data`) follow too:

```yaml
---
apiVersion: longhorn.io/v1beta2
kind: Setting
metadata:
  name: default-replica-count
  namespace: longhorn-system
# 2 worker nodes: see storageclasses.yaml. A 3rd replica cannot improve
# redundancy here, it only consumes another full copy of every volume.
value: "2"
```

**Existing volumes** - the 9 already-provisioned volumes keep `spec.numberOfReplicas: 3` until
patched:

```bash
kubectl -n longhorn-system get volumes.longhorn.io -o name \
  | xargs -I{} kubectl -n longhorn-system patch {} --type=merge \
      -p '{"spec":{"numberOfReplicas":2}}'
```

Longhorn drops the surplus replica per volume and reclaims the space without downtime.

### 2. Commit `kubev/manifests/longhorn-settings.yaml`

It is currently **untracked** - it exists only on one laptop. Everything keeping this cluster's
storage schedulable (`replica-soft-anti-affinity=true`, `storage-over-provisioning-percentage=200`)
is undocumented in the repo, so a rebuild silently reverts to defaults and reproduces the original
`ReplicaSchedulingFailure`.

Ideally fold it into a proper `kubeone/helm-values/longhorn.yaml` under `defaultSettings:` so the
config is declarative at install time rather than post-hoc `Setting` CRs. The Helm release
currently runs on **pure chart defaults with no values file at all**, which is the underlying
reason these settings had to be applied by hand.

### 3. Give the virtualization stack a priority class

Stops a full disk from cascading into deleted kube-ovn VPCs. This is the blast-radius fix and is
worth doing regardless of which capacity option is chosen.

In `kubeone/helm-values/kubevirt.yaml` (or the chart's deployment templates), set
`priorityClassName: system-cluster-critical` on `kubev-api-server`,
`kubev-controller-manager` and `kubev-vms`, matching how `longhorn-manager` already protects
itself with `system-node-critical`.

Giving the control-plane deployments real resource `requests` would also lift them out of
BestEffort, which is what puts them first in the queue today.

### 4. Lower over-provisioning once replicas are 2

`storage-over-provisioning-percentage=200` was raised on 2026-08-04 to work around the 3-replica
shortfall. Once replicas are 2 the shortfall is gone and it can go back toward 100, which restores
Longhorn's own guard against exactly this situation. Worth doing as a follow-up, after step 1 has
settled.

### 5. Garbage-collect the stale golden image

`windows-10-golden` (`pvc-ef62e1ed-...`) is **detached, robustness `unknown`**, 53.7G provisioned /
50.6G real - 161G of scheduled capacity for a volume nothing is using. Confirm it is not the
source for the Windows demos before removing it.

Also worth a periodic sweep: host-assisted CDI clones create a `tmp-pvc-<uid>` populator PVC with
**no ownerReferences**, so it is never garbage-collected. Orphans from failed clones sit on disk
indefinitely. One such orphan took wk-1 from 101.4G to 156.0G available on 2026-09-04.

## Deliberately not suggested: a third worker

A third worker would remove the anti-affinity packing and make 3 replicas meaningful. It is the
better long-term answer, but it needs hardware this issue cannot assume, and the cluster is fine on
two nodes once the replica count matches the node count. Raising it here only as context for
whoever owns the environment budget.

## Verification

After applying steps 1-3, the scheduled figure should drop below usable on both nodes:

```bash
kubectl -n longhorn-system get nodes.longhorn.io -o json | python3 -c '
import sys, json
for n in json.load(sys.stdin)["items"]:
    name = n["metadata"]["name"]
    for dn, ds in (n["spec"].get("disks") or {}).items():
        st = (n["status"].get("diskStatus") or {}).get(dn, {})
        mx = st.get("storageMaximum", 0)
        sc = st.get("storageScheduled", 0)
        usable = mx - ds.get("storageReserved", 0)
        print(f"{name}: scheduled {sc/1e9:.1f}G / usable {usable/1e9:.1f}G = {100*sc/usable:.0f}%")'
```

Today that prints:

```
kubev-demo-env-wk-1: scheduled 560.1G / usable 327.6G = 171%
kubev-demo-env-wk-2: scheduled 311.4G / usable 327.6G = 95%
```

Expected afterwards: both nodes under 100%, versus wk-1 at 171% today.

Then confirm the control plane is no longer BestEffort:

```bash
kubectl -n kubermatic-virtualization get pods -o custom-columns=\
'NAME:.metadata.name,PRIO:.spec.priorityClassName,QOS:.status.qosClass' | grep kubev-
```

## Related

- Local env notes and open TODO: `kubevirt-labs/hack/demo-setup/README.md`
- `migratable: "true"` on the StorageClass is load-bearing for KubeVirt RWX block volumes - see
  the comment already in `kubev/manifests/storageclasses.yaml`. None of the changes above touch it.
