# SSH bastion

A jump host into the kube-ovn subnets, exposed on the lab LAN by MetalLB.

```bash
ssh bastion@10.77.33.22                       # the bastion itself
ssh -J bastion@10.77.33.22 ubuntu@10.133.0.2  # a control-plane VM
just ssh                                      # the same thing, IP looked up for you
```

Deployed by `just infra-bastion` (part of `just infra`).

## Why it has to exist

KubeOne drives every node over SSH, and the VMs only ever get a kube-ovn
address - `10.133.0.x` for the control plane, `10.133.1.x` for the workers.
Nothing on `10.77.33.0/24` can route there, so without a jump host inside
kube-ovn, `kubeone apply` cannot reach a single machine.

```
laptop 10.77.33.198
  │  ssh bastion@10.77.33.22
  ▼
svc/ssh-bastion  10.77.33.22:22        MetalLB L2/ARP, ippool-kubev
  │  kube-proxy DNAT on kubev-host-01
  ▼
pod ssh-bastion  172.25.0.x            ovn-default
  │  TCP forward, inside the ovn-cluster VPC
  ▼
10.133.0.x / 10.133.1.x                the VMs
```

`kubeone.yaml` points at it with `ssh.bastion: "10.77.33.22"` and
`bastionUser: bastion`.

## Files

| File                   | What it is                                                     |
|------------------------|----------------------------------------------------------------|
| `00_bastion-pod.yaml`  | ConfigMaps (authorized_keys, sshd_config) + the Deployment      |
| `01_bastion-svc.yaml`  | `type: LoadBalancer` Service, pinned to `10.77.33.22`           |

Host keys are **not** in either file. `just infra-bastion` generates them once
into `secret/ssh-bastion-hostkeys` and never overwrites them, so the bastion
keeps its identity across restarts instead of invalidating every `known_hosts`
entry mid-provisioning. Delete that Secret to rotate them deliberately.

## Things that are not obvious

**One interface, not two.** This started as the FOG/BWI bastion, which is
dual-NIC: a multus primary on an external VLAN plus a secondary into the
internal VPC. That design solves a problem this box does not have. Here
`ovn-default` is the *default* subnet of the `ovn-cluster` VPC and
`kubeone-demo-cp` / `kubeone-demo-workers` sit in that same VPC, so one
interface already routes to everything - verified with `ping 10.133.0.1` from
inside the pod. The external hop is a Service on the node rather than a VLAN on
the pod, so there is no asymmetric-routing problem to design around either. And
this cluster has no `NetworkAttachmentDefinition` at all, so the multus
annotations would simply strand the pod in `Pending`.

**`echo 'bastion:*' | chpasswd -e` is load-bearing.** `adduser -D` leaves `!` in
the shadow field, which sshd reads as a *locked account* and refuses - including
for pubkey auth. The client just sees `Permission denied (publickey)`; the
reason is only visible in the sshd log as
`User bastion not allowed because account is locked`. `*` means no password can
ever match, without locking the account.

**`AllowTcpForwarding yes` is the whole point.** `ssh -J` and KubeOne's bastion
support both work by asking the jump host to open a TCP forward. Without it the
login succeeds and every hop fails.

**The MetalLB label.** MetalLB will not announce from a node carrying kubeadm's
`node.kubernetes.io/exclude-from-external-load-balancers`, and the KubeV
installer re-adds it on every apply. The VIP is then allocated but never ARPed,
so `EXTERNAL-IP` looks perfect while every connection times out.
`just infra-bastion` clears it first. To tell "announced" from merely
"allocated":

```bash
kubectl get servicel2statuses.metallb.io -A   # .status.node must be set
arp -n 10.77.33.22                            # must resolve to a MAC
```

**A Secret, not a PVC.** Three small key files do not need a volume, and a
Secret has no dependency on storage working and survives the node's disk being
wiped - which a `local-path` hostPath volume does not.

**Restarting needs egress.** The container `apk add openssh` on startup, so a
pod restart while the edge box is offline will not come back. `ovn-default` has
`natOutgoing: true`, so it works whenever the uplink does.

## LAN address allocation

MetalLB pool `ippool-kubev` is `10.77.33.20-10.77.33.50`:

| Address        | Service                                              |
|----------------|------------------------------------------------------|
| `10.77.33.20`  | KubeV dashboard                                      |
| `10.77.33.21`  | KubeOne kube-apiserver (`infra/api-lb-svc.yaml`)     |
| `10.77.33.22`  | this bastion                                         |
| `10.77.33.23`  | Headlamp                                             |

The pool sits below the router's DHCP range (`10.77.33.100-.199`), so nothing on
the LAN can hand these out.
