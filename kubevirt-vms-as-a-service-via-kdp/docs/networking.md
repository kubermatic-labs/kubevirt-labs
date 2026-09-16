# Networking

How `Vpc` and `Subnet` map onto kube-OVN, why a VM has to reference both, and where traffic
in and out of a tenant network actually goes.

For the annotation-level detail of attaching an ordinary VM to an existing subnet on this
cluster, see [kubevirt-vm-vpc-subnet-selection.md](kubevirt-vm-vpc-subnet-selection.md).

## The network kinds wrap KubeVirtualization's own API

`Vpc` and `Subnet` do not create `kubeovn.io` objects directly. They create
KubeVirtualization's namespaced wrapper kinds (`virtualization.k8c.io/v1alpha1`), and the
wrapper controller owns the kube-OVN object underneath. Two reasons this matters:

- The **KubeV dashboard lists wrappers**, not kube-OVN objects. Creating kube-OVN objects
  directly left these networks invisible there.
- The wrapper also provisions a **NetworkAttachmentDefinition** and gives the kube-OVN
  Subnet a matching `provider`. VMs attach through multus rather than pod annotations,
  which is the attachment model the rest of KubeVirtualization uses.

The wrapper names the kube-OVN object `<namespace>-<name>`, with `-sn` appended for
subnets, and surfaces it as `status.realName`. Everything downstream reads that field
rather than rebuilding the name.

## Subnet names are limited to 13 characters

The wrapper copies the NAD name into a Kubernetes *label value*, which is capped at 63
characters, and the prefix `kubermatic-virtualization-kdp-<cluster>-` plus the `-sn` suffix
already consumes 50 of them. A longer name leaves the Subnet stuck in `Provisioning` with
`metadata.labels: Invalid value: ... must be no more than 63 characters` in the
kubev-controller-manager log and nothing at all on the object itself. That is an upstream
bug, not something this service can work around; the examples use `ubuntu-net` and
`windows-net` to stay inside the budget.

## Mistyping a subnet blocks the VM instead of half-creating it

A VM needs a Subnet and a Subnet needs a Vpc, but `spec.subnet` and `spec.vpc` are plain
strings, so nothing stops a typo. The VM RGDs close that with two read-only `externalRef`
handles, `tenantVpc` and `tenantSubnet`, pointing at the kube-OVN objects the other two
kinds already created. The VM's `logical_router` / `logical_switch` annotations reference
those ids rather than rebuilding the name inline, and the LoadBalancer Service carries
`kubev.k8c.io/subnet: ${tenantSubnet.metadata.name}`.

Those references are the whole mechanism - kro builds its DAG from CEL references and has no
explicit `dependsOn`. Name a subnet that does not exist and the instance parks at
`IN_PROGRESS` reporting `waiting for external reference "tenantSubnet": not found`, with no
VirtualMachine, no Service and no public IP created. Fix the name and it proceeds. Nothing is
ever deleted: kro disables prune while anything is unresolved, so mistyping the field on a
running VM does not destroy it.

The Service label is not decoration. Without a reference to `tenantSubnet` the Service has no
edge to the gate, and a typo still allocates a public IP for a VM that will never exist.

The api-syncagent's Related Resources feature does not do this. It copies satellite objects
(Secrets, ConfigMaps, other published kinds) alongside a primary object; a reference to a
missing field is deliberately treated as "not yet existing" rather than an error.

## Outbound: why a custom VPC needs an egress gateway

A custom kube-OVN VPC has **no outbound path at all** out of the box. Three things that look
like they should provide one, and do not:

- `Subnet.spec.natOutgoing` only SNATs the **default** VPC (`ovn-cluster`) from the node. In a
  custom VPC it is a no-op. The field is still exposed because it is the familiar knob.
- `Vpc.spec.enableExternal` / `extraExternalSubnets` need external gateway nodes - an
  `ovn-external-gw-config` ConfigMap plus labelled nodes. This cluster has neither, so
  kube-ovn-controller rejects it on every reconcile with `no external gw nodes` and
  `status.enableExternal` stays `false`. The RGD no longer sets it.
- **VPC peering is not a substitute.** It joins two VPC routers so their subnets can reach
  each other; it performs no SNAT and creates no path to the outside.

What does work is a `VpcEgressGateway`: a small Deployment with one NIC in the tenant subnet
and one in a provider-backed subnet of the default VPC, MASQUERADEing on the way out. The
Subnet RGD creates **one per subnet** (`spec.egressGateway`, default `true`), so each tenant
gets its own and they are torn down with the subnet.

It needs one **cluster-wide** prerequisite, applied once:
`service-cluster/vpc-egress-external.yaml` - a NetworkAttachmentDefinition plus a
`172.30.0.0/24` Subnet in the default VPC carrying a matching `provider`. The gateway
attaches through multus, so an ordinary subnet such as `ovn-default` cannot be used; it is
rejected with `please set correct provider of subnet ... to get the
network-attachment-definition`.

So: **the gateway is per VPC (here per subnet); the external network it attaches to is
central.**

This is also why guest DNS has to be pinned to a public resolver rather than the cluster DNS
service IP - see *SSH and the guest agent* in [api-reference.md](api-reference.md).

## Inbound: the LoadBalancer IP

The Service gets a public IP, but KubeLB's last hop is `nodeIP:nodePort`, which reaches VMs
on `ovn-default` and not VMs inside a custom VPC. The Service and its endpoint are correct
in-cluster; the public path is a known infrastructure gap, not an error in this RGD.
