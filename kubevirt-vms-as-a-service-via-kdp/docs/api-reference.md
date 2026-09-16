# API reference

All four kinds are served under `kubev.k8c.io/v1alpha1`. They are what a platform user sees
in a KDP workspace after `just kdp-bind`; the objects they turn into on the service cluster
are described in [`../README.md`](../README.md).

| Kind                    | Creates                                       |
|-------------------------|-----------------------------------------------|
| `Vpc`                   | `kubeovn.io/v1` Vpc                           |
| `Subnet`                | `kubeovn.io/v1` Subnet                        |
| `LinuxVirtualMachine`   | KubeVirt VM + DataVolume (Ubuntu or Flatcar)  |
| `WindowsVirtualMachine` | KubeVirt VM + LoadBalancer Service (RDP 3389) |

`Vpc` and `Subnet` are covered in [networking.md](networking.md) - their fields only make
sense next to the kube-OVN behaviour they wrap.

## LinuxVirtualMachine

### OS and image

`LinuxVirtualMachine` picks the guest with two enums:

| `spec.os` | `spec.image`                                           | Preference | cloud-init           |
|-----------|--------------------------------------------------------|------------|----------------------|
| `ubuntu`  | `quay.io/kubermatic-virt-disks/ubuntu:24.04-amd64`     | `ubuntu`   | NoCloud cloud-config |
| `ubuntu`  | `quay.io/kubermatic-virt-disks/ubuntu:22.04`           | `ubuntu`   | NoCloud cloud-config |
| `flatcar` | `quay.io/kubermatic-virt-disks/flatcar:4593.2.3-amd64` | `linux`    | ConfigDrive Ignition |

The RGD carries one `VirtualMachine` template per OS, selected with `includeWhen`, because
the two guests need different cloud-init mechanisms - Flatcar is Ignition-only and has no
KubeVirt preference of its own, so it uses the generic `linux` one. Both templates emit the
same object name, so the status wiring is identical either way.

The images are imported from the registry with CDI (`source.registry`), not fetched over
HTTP, so adding a value means adding a tag that exists in
[quay.io/kubermatic-virt-disks](https://quay.io/organization/kubermatic-virt-disks).

**`os` and `image` are two independent dropdowns, not a cascade.** KDP's form has no way to
filter one field by another field's value (see [kdp-ui.md](kdp-ui.md)), so picking
`os: flatcar` with an `ubuntu:*` image is accepted by the API server and simply boots Ubuntu
with the wrong preference. The field descriptions spell out the pairing.

### SSH and the guest agent

`LinuxVirtualMachine` creates a `LoadBalancer` Service on port 22 alongside the VM, the same
shape as the Windows kind's RDP Service, selecting the VM's virt-launcher pod by
`kubevirt.io/vm`. `spec.loadBalancerClass` defaults to `kubelb`. Status carries
`loadBalancerIP`, `port` and `nodePort`.

cloud-init creates a key-only `kkp` user from `spec.sshPublicKey`, keeps the
password-authenticated `kubevirt` user for console access, and installs
`qemu-guest-agent` - which is what makes `.status.guestOSInfo` and the reported IPs
appear in KDP. Flatcar has no package manager, so its Ignition branch enables the agent as a
systemd unit guarded by `ConditionPathExists=/usr/bin/qemu-ga` instead.

**DNS has to be pinned.** A VM on a per-tenant kube-OVN VPC cannot route to the cluster DNS
service IP, so `dnsPolicy: None` + `8.8.8.8` is set explicitly. Without it the guest gets
`10.96.0.10`, `apt` cannot resolve, and the guest agent install fails silently. The
underlying reason a tenant VPC has no path to cluster DNS is in
[networking.md](networking.md).

### Disk size

`spec.diskSize` is free-form on the Linux kind on purpose - it imports from a registry
rather than cloning a PVC, so any size at or above the image is valid.

## WindowsVirtualMachine

### Golden image

`spec.templateImageName` is an enum; `windows-10-golden` is the only golden image PVC on the
cluster today. Add values to the enum in the RGD as more golden images appear.

The golden image is cloned same-namespace, **Block to Block**. A filesystem target fails the
clone on `lost+found`.

### Disk size

`spec.diskSize` is an enum (`50Gi`, `100Gi`, `200Gi`) rather than a free-form string, because
the Windows kind *clones* the `windows-10-golden` PVC and **a CDI clone can grow but never
shrink**. A target smaller than the 50Gi source is rejected by CDI with
`CloneValidationFailed`, and CDI then goes completely silent: it writes no DataVolume phase,
creates no target PVC and emits no Event, so the VM sits `Stopped` forever with nothing
pointing at the cause. Keep the smallest enum value at or above the golden image PVC size,
and widen the enum when a larger golden image is added.

### RDP

The Windows kind creates a `LoadBalancer` Service on port 3389. The public path to it is
currently broken; see *Inbound* in [networking.md](networking.md).

## Instance types

Both VM kinds pick their size from a `VirtualMachineClusterInstancetype`, constrained by an
`enum` in the schema so the dashboard renders a dropdown and the API server rejects anything
else. Only `u1.*` types are offered: `cx1`/`m1`/`n1`/`rt1` need cpumanager or hugepages and
land in `ErrorUnschedulable` on these nodes.

| Kind                    | Allowed instance types                        | Default     |
|-------------------------|-----------------------------------------------|-------------|
| `LinuxVirtualMachine`   | all 10 `u1.*`, from `u1.nano` to `u1.8xlarge` | `u1.medium` |
| `WindowsVirtualMachine` | `u1.large` and larger (5 types)               | `u1.large`  |

Because a KubeVirt VM may not set an instance type *and* explicit cpu/memory, the Linux kind
does not take `cpu`/`memory` - it takes `instanceType` and a preference chosen by `spec.os`.

## Changing the schema

Adding a field is cheap. Removing one is not: kro refuses the CRD update, and it does so
while still reporting `Active`. Read [troubleshooting.md](troubleshooting.md) before editing
an RGD schema, and follow the runbook in [operations.md](operations.md#after-an-rgd-schema-change)
afterwards.
