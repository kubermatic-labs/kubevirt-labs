# KubeOne on KubeVirt

Spin up a Kubernetes cluster whose nodes are KubeVirt VMs, with **one command**.

KubeOne 1.14 provisions the control-plane VMs itself through the machine-controller
KubeVirt provider, so `controlPlane.nodeSets` in [`kubeone.yaml`](kubeone.yaml) is
the entire control plane and `dynamicWorkers` is the entire worker fleet. There is
no VM manifest, no Helm chart for VMs and no IP planning in this directory.

```bash
just up
```

| File                     | What it is                                                                          |
|--------------------------|-------------------------------------------------------------------------------------|
| `.env`                   | Names, namespace and kubeconfig paths the Justfile uses                             |
| `kubeone.yaml`           | The demo cluster on the kubev demo environment. Runs as-is.                         |
| `kubeone.example.yaml`   | Annotated template for any KubeVirt environment, incl. the VPC-per-cluster variant. |
| `infra/network/subnet-k1-cp.yaml`     | Kube-OVN subnets for the control plane and the workers                              |
| `infra/rbac.yaml`        | ServiceAccount + RBAC in the infra cluster, templated                               |
| `infra/sa-kubeconfig.sh` | Applies that RBAC and mints the kubeconfig KubeOne uses                             |
| `infra/helmfile.yaml`    | gobetween TCP load balancer in front of the kube-apiserver                          |
| `apps/`                  | Optional, applied to the new cluster after it is up                                 |

`apps/` is deliberately not called `addons/` - KubeOne has its own addon
mechanism and would try to apply anything it finds there.

## Prerequisites

- `kubeone` **>= 1.14**, plus `kubectl`, `helm`, `helmfile`, `just`
- **Tailscale up.** `tobi-demo-bastion` is how KubeOne reaches the VMs, and its
  advertised `172.16.0.0/16` route is how `kubectl` later reaches the API VIP.
  See [`hack/demo-setup/`](../../hack/demo-setup/) for the bastion itself.
- **Your SSH key in the agent** - `kubeone.yaml` uses `agentSocket`, not a key file.
  Check with `ssh-add -l`.
- **The infra cluster kubeconfig.** Either

  ```bash
  export KUBEV_KUBECONFIG=/path/to/kubev-cluster-kubeconfig
  ```

  or drop a copy/symlink at `kubernetes/kubeone/kubev-kubeconfig` - `*kubeconfig`
  is gitignored.

`just preflight` checks all of it and tells you what is missing.

## Configuration

Everything the Justfile needs lives in [`.env`](.env) - cluster name, infra
namespace, subnet and load-balancer names, kubeconfig paths, the KubeLB version.
Edit it there; the Justfile only holds fallbacks for when `.env` is absent.

A real environment variable beats `.env`, so a one-off needs no edit:

```bash
CLUSTER_NAME=scratch just status
KUBEV_KUBECONFIG=/somewhere/else/kubeconfig just preflight
```

Kubeconfig paths take a bare filename (resolved next to the Justfile) or an
absolute path. `just --evaluate` prints every value as finally resolved.

Two names are duplicated between `.env` and `kubeone.yaml` - `CLUSTER_NAME` vs
`name:`, and `INFRA_NAMESPACE` vs `cloudProvider.kubevirt.infraNamespace` -
because KubeOne does not template its own manifest. `just preflight` compares
them and fails on a mismatch, since a drift would point every recipe at objects
that do not exist.

`PURGE_NAMESPACE` guards `just purge`. It defaults to `false` because
`INFRA_NAMESPACE` is shared with the rest of the demo environment; purge deletes
only this cluster's VMs, subnets and IPPool and leaves the namespace standing.
Set it to `true` only for a namespace dedicated to this cluster.

## Running it

```bash
just up          # preflight -> infra -> kubeone apply -> kubeconfig -> nodes
```

Roughly 8-12 minutes, most of it CDI importing the Ubuntu image. Step by step:

```bash
just preflight       # tools, kubeconfig, ssh-agent, bastion reachable
just infra           # subnets + RBAC/SA kubeconfig + API load balancer
just apply           # kubeone apply - creates the VMs, then kubeadm, then workers
just kubeconfig      # writes ./kubev-demo-kubeconfig
```

Then:

```bash
export KUBECONFIG=$PWD/kubev-demo-kubeconfig
kubectl get nodes

just status          # VMs, disks, LB and control-plane addresses in the infra cluster
just watch           # follow the VMs coming up
just ssh             # shell on kubev-demo-cp-0, through the bastion
```

Optional extras, not part of `just up`:

```bash
just app-storage     # default StorageClass in the new cluster, backed by kubev-vms
just app-kubelb      # KubeLB CCM (needs a tenant on the KubeLB management cluster)
```

Teardown:

```bash
just down            # kubeone reset --destroy-workers, then purge
just purge           # delete the VMs, namespace, subnets and IPPool directly
```

`kubeone reset` destroys the MachineDeployment workers and resets the nodes over
SSH, but it never deletes the control-plane VMs it created - that is what
`purge` is for.

## How it fits together

```
your laptop
   │  ssh (KubeOne tunnels the Kubernetes API through this too)
   ▼
tobi-demo-bastion ── tailnet, advertises 172.16.0.0/16
   │
   ├─ ovn-default 172.16.0.0/16 ── gobetween 172.16.200.10:6443  ← apiEndpoint
   │                                    │  TCP healthcheck + forward
   ▼                                    ▼
kubeone-demo-cp   10.180.0.0/29 ── kubev-demo-cp-0      (KubeOne + kubeadm)
kubeone-demo-workers 10.180.1.0/24 ── kubev-demo-worker-* (machine-controller)
```

Three things in here are not obvious.

**Why gobetween and not KubeOne's own Service.** KubeOne can create a Service
for the API endpoint (`cloudProvider.kubevirt.controlPlane.loadBalancer`), but it
cannot set `spec.loadBalancerClass`. On this cluster nothing would give that
Service an address: MetalLB's pool is a single, already-used IP, and only
`loadBalancerClass: kubelb` yields a public one. Setting `apiEndpoint.host`
makes KubeOne skip Service creation entirely, so a kube-ovn native load balancer
owns the endpoint instead. It is also the shape that survives moving the cluster
into its own VPC.

**Why the control-plane subnet is a `/29`.** gobetween needs a static list of
backends, but machine-controller cannot pin a VM's IP - it only ever sets
`ovn.kubernetes.io/logical_switch`, so kube-ovn assigns from the subnet. A `/29`
has five usable addresses, all five are listed as backends, and gobetween's
`ping` healthcheck is a **TCP dial** (not ICMP, whatever the chart README says).
Addresses without a live apiserver simply never receive traffic. No pinning, no
drift, room to go to `replicas: 3` without touching the LB.

**Why `natOutgoing: true` matters.** A kube-ovn subnet without it has no egress
at all, and kubeadm has to reach registry.k8s.io and the Ubuntu archives. Both
subnets sit in the default VPC (`ovn-cluster`) so they are also routed to
`ovn-default`, which is what lets the bastion SSH in and the gobetween pod reach
the control plane.

## Sizing

Default is **1 control plane + 1 worker**, 2 vCPU / 8 GiB / 30 GiB each.

The demo environment has two schedulable nodes (the three control-plane nodes are
tainted) and the `kubev-vms` StorageClass asks Longhorn for three replicas on
those two nodes, so every GiB of VM disk costs roughly 2x on disk. `wk-1` is
already over-subscribed. Check `just status` and Longhorn before scaling up.

To scale: `replicas:` under `controlPlane.nodeSets[0]` (the `/29` and the
gobetween backend list already have room for 3) or under `dynamicWorkers[0]`,
then `just apply`.

## Gotchas

- **`apiVersion` is `v1beta2`, not `v1beta3`.** The v1beta3 types exist in the
  KubeOne source and the upstream docs use them, but v1.14.3 still rejects that
  apiVersion in its config loader. `nodeSets` and the KubeVirt control-plane
  spec are identical in v1beta2.
- **VM disks must use `kubev-vms`.** The infra default (`longhorn`) cannot serve
  a raw block device and the CDI import hangs forever.
- **`KUBEVIRT_KUBECONFIG` is passed as plain YAML, not base64.** KubeOne puts the
  value straight into the secret the CCM and CSI driver mount as a kubeconfig
  file, so a base64 blob would break them. machine-controller accepts either.
- **`kubeone config dump` hangs** on a manifest with `nodeSets` unless the
  KubeVirt credentials are real - it tries to look the VMs up. Use
  `kubeone config machinedeployments` to sanity-check a manifest offline.
