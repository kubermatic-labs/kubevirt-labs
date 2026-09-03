# Choosing the VPC / subnet for a KubeVirt VM

Which annotations a VM needs to land on a specific kube-ovn subnet on the
`demo-envs-dc-kubevirt` cluster. All examples below are read off VMs actually running
there, not from upstream docs.

## Available subnets

```console
$ kubectl get subnets.kubeovn.io
```

| Subnet (= `logical_switch`)                     | CIDR             | Gateway       | VPC                                       | Attach via                    |
|-------------------------------------------------|------------------|---------------|-------------------------------------------|-------------------------------|
| `ovn-default`                                   | `172.16.0.0/16`  | `172.16.0.1`  | `ovn-cluster`                             | plain pod network, **no NAD** |
| `kubermatic-virtualization-tenant-subnet-01-sn` | `10.166.10.0/24` | `10.166.10.1` | `kubermatic-virtualization-tenant-vpc-01` | multus NAD                    |
| `kubermatic-virtualization-workload-a-sn`       | `10.0.166.0/24`  | `10.0.166.1`  | `kubermatic-virtualization-demo-vpc`      | multus NAD                    |

`join` (`100.64.0.0/16`) is internal kube-ovn plumbing - never attach a VM to it.

## The annotation key format

For a **multus / VPC subnet** the annotation key is prefixed with the subnet's *provider*:

```
<nad-name>.<nad-namespace>.ovn.kubernetes.io/logical_switch: <subnet-name>
```

The prefix is exactly the subnet's `.spec.provider` (which is `<nad-name>.<nad-namespace>.ovn`)
with `.kubernetes.io/<key>` appended. Read it straight off the subnet, never hand-assemble it:

```console
$ kubectl get subnet kubermatic-virtualization-tenant-subnet-01-sn -o jsonpath='{.spec.provider}'
kubermatic-virtualization-tenant-subnet-01-sn.kubermatic-virtualization.ovn
```

For **`ovn-default`** there is no provider prefix - use the plain `ovn.kubernetes.io/*` keys.

Annotations go on **`spec.template.metadata.annotations`** (the VMI template), *not* on the
VirtualMachine's own metadata.

## Example: VM on a VPC subnet

Working reference - this is `vm/netgo`, which came up on `10.166.10.7`:

```yaml
spec:
  template:
    metadata:
      annotations:
        kubermatic-virtualization-tenant-subnet-01-sn.kubermatic-virtualization.ovn.kubernetes.io/logical_switch: kubermatic-virtualization-tenant-subnet-01-sn
    spec:
      domain:
        devices:
          interfaces:
          - name: net0
            bridge: {}
            model: virtio
      networks:
      - name: net0
        multus:
          default: true
          networkName: kubermatic-virtualization/kubermatic-virtualization-tenant-subnet-01-sn
```

Two halves, both required:

- **`networks[].multus.networkName`** - `<nad-namespace>/<nad-name>` - attaches the NIC.
- **the annotation** - picks the subnet on that provider and is what kube-ovn reads for IPAM.

`multus.default: true` makes this the VM's default-route interface. With a single NIC that is
what you want; with several, set it on exactly one or the VM ends up with no default route (or
a fight over it).

For `workload-a-sn` swap both strings:

```yaml
        kubermatic-virtualization-workload-a-sn.kubermatic-virtualization.ovn.kubernetes.io/logical_switch: kubermatic-virtualization-workload-a-sn
          networkName: kubermatic-virtualization/kubermatic-virtualization-workload-a-sn
```

## Example: VM on the default pod network

Plain keys, no NAD, no multus - this is `vm/tobi-demo-bastion`:

```yaml
spec:
  template:
    metadata:
      annotations:
        ovn.kubernetes.io/logical_switch: ovn-default
        ovn.kubernetes.io/ip_address: 172.16.15.255   # optional, pins the address
    spec:
      domain:
        devices:
          interfaces:
          - name: default
            bridge: {}
            model: virtio
      networks:
      - name: default
        pod: {}
```

## Optional extras

Same prefix rule - plain `ovn.kubernetes.io/` on `ovn-default`, provider-prefixed on a VPC
subnet:

| Key                | Effect |
| ------------------ | ------ |
| `.../ip_address`   | pin a fixed IP (must be inside the subnet CIDR and free) |
| `.../mac_address`  | pin the MAC |
| `.../ip_pool`      | restrict IPAM to a range within the subnet |
| `ovn.kubernetes.io/allow_live_migration` | set `"true"` on `ovn-default` VMs that should live-migrate |

kube-ovn runs with `--keep-vm-ip=true`, so a VM keeps its address across reboots and live
migration even without an explicit pin.

## Rules enforced by Kyverno

ClusterPolicy **`enforce-vm-vpc-namespace-slice`**, two rules, both on `VirtualMachine`:

1. **`vm-vpc-namespace-slice`** - only fires when the VM sets
   `ovn.kubernetes.io/logical_router`. The VM's namespace must appear in that VPC's
   `spec.namespaces`, else it is denied with
   *"VM namespace 'X' is not part of configured namespaces for vpc 'Y'"*.
   Both tenant VPCs currently allow only **`kubermatic-virtualization`**:

   ```console
   $ kubectl get vpc -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.namespaces}{"\n"}{end}'
   kubermatic-virtualization-demo-vpc       ["kubermatic-virtualization"]
   kubermatic-virtualization-tenant-vpc-01  ["kubermatic-virtualization"]
   ```

2. **`vm-ovn-annotations-immutable`** - on UPDATE, `ovn.kubernetes.io/logical_router` and
   `ovn.kubernetes.io/logical_switch` **cannot change**. Moving an existing VM to another
   subnet means delete + recreate. To keep the disks:

   ```bash
   kubectl delete vm <name> -n kubermatic-virtualization --cascade=orphan
   # edit the manifest, then re-apply; the PVCs are picked up again
   ```

   Note this rule matches the *unprefixed* keys, so it does not literally block editing a
   provider-prefixed annotation - but KubeVirt still will not re-plumb a running VM, so treat
   the subnet as fixed at creation either way.

Both rules set `allowExistingViolations: true`, so pre-existing VMs are grandfathered in.

## Reachability - pick the subnet accordingly

The VPC subnets are **isolated**. `kubermatic-virtualization-tenant-vpc-01` and
`kubermatic-virtualization-demo-vpc` have no `vpcPeerings` and no `staticRoutes`, so from a
VM on `ovn-default` both gateways are unreachable (`ping 10.166.10.1` fails), and vice versa.

- Needs to be reachable from the cluster/pod plane, from the KubeLB path, or from the
  bastion → **`ovn-default`**.
- Wants tenant isolation and only talks to VMs in the same VPC → **a VPC subnet**.

An earlier revision of the bastion lived on `workload-a-sn` and was unreachable from the
cluster plane, which is why it was rebuilt on `ovn-default`. If a VM needs both, give it two
NICs (`pod: {}` plus a multus NIC) rather than moving it.

## Check what a VM actually got

```bash
kubectl -n kubermatic-virtualization get vmi <name> \
  -o jsonpath='{range .status.interfaces[*]}{.name}{" "}{.ipAddress}{"\n"}{end}'
```
