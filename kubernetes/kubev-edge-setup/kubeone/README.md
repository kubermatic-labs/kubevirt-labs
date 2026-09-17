# KubeOne on KubeVirt

Spin up a Kubernetes cluster whose nodes are KubeVirt VMs, with **one command**.

KubeOne 1.14 provisions the control-plane VMs itself through the machine-controller
KubeVirt provider, so `controlPlane.nodeSets` in [`kubeone.yaml`](kubeone.yaml) is
the entire control plane and `dynamicWorkers` is the entire worker fleet. There is
no VM manifest, no Helm chart for VMs and no IP planning in this directory.

```bash
just up
```

| File                     | What it is                                                                    |
|--------------------------|-------------------------------------------------------------------------------|
| `.env`                   | Names, namespace, VIPs and kubeconfig paths the Justfile uses                 |
| `kubeone.yaml`           | The cluster itself, VMs and Helm releases included. Runs as-is.               |
| `infra/network/`         | Kube-OVN subnets for the control plane and the workers                        |
| `infra/rbac.yaml`        | ServiceAccount + RBAC in the infra cluster, templated                         |
| `infra/sa-kubeconfig.sh` | Applies that RBAC and mints the kubeconfig KubeOne uses                       |
| `infra/helmfile.yaml`    | gobetween TCP load balancer in front of the kube-apiserver                    |
| `infra/api-lb-svc.yaml`  | MetalLB Service that puts that load balancer on the edge LAN at `10.77.33.21` |
| `ssh-bastion/`           | SSH jump host into the kube-ovn subnets, on the LAN at `10.77.33.22`          |
| `apps/`                  | Optional, applied to the new cluster after it is up                           |

`apps/` is deliberately not called `addons/` - KubeOne has its own addon
mechanism and would try to apply anything it finds there.

## Prerequisites

- `kubeone` **>= 1.14**, plus `kubectl`, `helm`, `helmfile`, `just`
- **On the lab LAN** (`10.77.33.0/24`). `kubectl` reaches the new cluster at
  `https://10.77.33.21:6443`, a MetalLB address on the KubeV cluster - see
  `infra/api-lb-svc.yaml`. No Tailscale and no bastion involved in that path.
  If you are on Tailscale with an exit node, turn on *Allow LAN Access* or the
  exit node swallows `10.77.33.0/24`.
- **Your SSH key in the agent** - `kubeone.yaml` uses `agentSocket`, not a key file.
  Check with `ssh-add -l`.
- **The infra cluster kubeconfig.** Either

  ```bash
  export KUBEV_KUBECONFIG=/path/to/kubev-cluster-kubeconfig
  ```

  The default in `.env` is `../kubermatic-virtualization/kubev-cluster-kubeconfig`,
  i.e. the one the KubeV install next door already wrote, so normally there is
  nothing to do. `*kubeconfig` is gitignored either way.

`just preflight` checks all of it and tells you what is missing.

## Configuration

Everything the Justfile needs lives in [`.env`](.env) - cluster name, infra
namespace, subnet names, the three LAN VIPs (kube-apiserver, SSH bastion,
Headlamp) and the kubeconfig paths. Edit it there; the Justfile only holds
fallbacks for when `.env` is absent.

A real environment variable beats `.env`, so a one-off needs no edit:

```bash
CLUSTER_NAME=scratch just status
KUBEV_KUBECONFIG=/somewhere/else/kubeconfig just preflight
```

Kubeconfig paths take a bare filename (resolved next to the Justfile) or an
absolute path. `just --evaluate` prints every value as finally resolved.

Three values are duplicated between `.env` and `kubeone.yaml`, because KubeOne
does not template its own manifest:

| `.env`            | `kubeone.yaml`                            |
|-------------------|-------------------------------------------|
| `CLUSTER_NAME`    | `name:`                                   |
| `INFRA_NAMESPACE` | `cloudProvider.kubevirt.infraNamespace`   |
| `HEADLAMP_VIP`    | the `metallb.io/loadBalancerIPs` annotation |

`just preflight` compares all three and fails on a mismatch, since a drift would
point every recipe at objects that do not exist.

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
just preflight       # tools, kubeconfig, ssh-agent, config drift
just infra           # subnets + RBAC/SA kubeconfig + API load balancer + SSH bastion
just apply           # kubeone apply - creates the VMs, then kubeadm, then workers
just kubeconfig      # writes ./kubev-k1-edge-kubeconfig
```

Then:

```bash
export KUBECONFIG=$PWD/kubev-k1-edge-kubeconfig
kubectl get nodes

just status          # VMs, disks, LB, bastion and control-plane addresses in the infra cluster
just watch           # follow the VMs coming up
just ssh             # shell on kubev-k1-edge-cp-0, through the bastion
```

## Headlamp

A workload UI for the new cluster, deployed by `just apply` itself: it is a
top-level `helmReleases` entry in `kubeone.yaml`, so KubeOne reconciles it on
every apply (`helm upgrade --install`). Nothing extra to run at provisioning
time.

```bash
just headlamp          # login token + the LAN address
just headlamp-forward  # fallback: tunnel to localhost:8081 when off the lab LAN
```

Unlike the DC variant, which is a NodePort, this one is a real `LoadBalancer`
Service - because here the KubeVirt CCM has somewhere to put the address:

```
your laptop  10.77.33.198
   │  http://10.77.33.23
   ▼
edge LAN 10.77.33.0/24
   │
   ├─ svc/a<uid>  10.77.33.23:80   MetalLB (L2/ARP), in kubermatic-virtualization
   │      ▲                         created by the KubeVirt CCM, selecting
   │      │                           cluster.x-k8s.io/role: worker
   │      │                           cluster.x-k8s.io/cluster-name: kubev-k1-edge
   │      └─ mirrors svc/headlamp in the KubeOne cluster, annotations and all
   ▼  kube-proxy DNAT on kubev-host-01
virt-launcher pod == the VM, on <nodePort>
   ▼  tenant kube-proxy
headlamp pod :4466
```

`cloudProvider.kubevirt.loadBalancerEnabled: true` switches on
cloud-provider-kubevirt's LoadBalancer controller. For every `type:
LoadBalancer` Service in the KubeOne cluster it creates a mirror Service in
`infraNamespace`, also of type LoadBalancer, pointed at that Service's
`nodePort`. MetalLB gives the mirror an address and the CCM copies it back into
the tenant Service as `EXTERNAL-IP`. Two details worth knowing:

- **Annotations are copied verbatim** onto the mirror, which is the only reason
  `metallb.io/loadBalancerIPs` works from inside `kubeone.yaml` - MetalLB runs
  in the infra cluster, not in the KubeOne one. That pins the demo URL to
  `HEADLAMP_VIP` (`.env`), the fourth address of `ippool-kubev`: `.20` is the
  KubeV dashboard, `.21` the kube-apiserver, `.22` the SSH bastion.
- **The mirror is named `a<service-uid>`**, not `headlamp`. Never look for it by
  name; read `EXTERNAL-IP` off the tenant Service, which is what `just headlamp`
  does.

Both VMs are backends: KubeOne labels the control-plane VM
`cluster.x-k8s.io/role: worker` too, so the CCM's selector matches it as well.

Headlamp asks for a ServiceAccount token rather than a password; `just headlamp`
prints an 8h one to paste in. The ServiceAccount is bound to `cluster-admin` -
deliberate for a demo, and worth scoping down with a read-only ClusterRole given
the UI sits on the LAN. Swap `clusterRoleBinding.clusterRoleName` in
`kubeone.yaml`.

If `EXTERNAL-IP` stays `<pending>`, it is the CCM; if it is set but nothing
connects, it is the same MetalLB trap as the API VIP - a node carrying kubeadm's
`node.kubernetes.io/exclude-from-external-load-balancers` label is never ARPed
for. `just headlamp` prints `ANNOUNCED-FROM` for exactly that reason; `just
infra-lb` clears the label.

Optional extras, not part of `just up`:

```bash
just app-storage     # default StorageClass in the new cluster, backed by kubev-vms
just ui              # kubeone's own web UI for the cluster (port 8080)
```

There is no KubeLB here. `just app-kubelb` exists in the Justfile, but its
`apps/kubelb-ccm/` inputs live only in the DC tree - MetalLB on the lab LAN
covers what KubeLB would do on this box. Copy
`../../kubev-dc/kubeone/apps/kubelb-ccm/` over and set `KUBELB_VERSION` in
`.env` if you ever need it.

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
your laptop  10.77.33.198
   │  kubectl -> https://10.77.33.21:6443
   ▼
edge LAN 10.77.33.0/24
   │
   ├─ svc/kubeone-demo-api-lb-lan   10.77.33.21:6443   ← apiEndpoint.host
   │        │  MetalLB (L2/ARP), kube-proxy DNAT on kubev-host-01
   ▼        ▼
ovn-default 172.25.0.0/24 ── gobetween 172.25.0.200:6443   (alternativeNames)
   │                              │  TCP healthcheck + forward
   ▼                              ▼
kubeone-demo-cp   10.133.0.0/24 ── kubev-k1-edge-cp-0      (KubeOne + kubeadm)
kubeone-demo-workers 10.133.1.0/24 ── kubev-k1-edge-worker-* (machine-controller)
```

**Two addresses, one load balancer.** `10.77.33.21` is a MetalLB Service in
front of the gobetween pod and is the only address reachable from the laptop -
`172.25.0.0/24` is the KubeV pod network and is not routed onto the LAN. It is
`apiEndpoint.host`, so kubeadm uses it as `controlPlaneEndpoint` and the nodes
dial it as well: out of kube-ovn, onto the LAN, back in through kube-proxy. One
address for everyone, which on a one-node box is the simpler story.

`172.25.0.200` is the same gobetween pod's pinned kube-ovn address, kept in
`apiEndpoint.alternativeNames` so it stays in the apiserver certificate. Putting
it back in `host` keeps the cluster's own traffic inside kube-ovn with no
hairpin, and needs no new certificate - `just kubeconfig` rewrites the generated
kubeconfig to the LAN VIP for exactly that case.

The chart (`kubeovn-gobetween` v0.2.0) renders only a Deployment, ConfigMap,
IPPools and a PriorityClass - no Service - which is why `api-lb-svc.yaml` is a
separate file that `helmfile sync` leaves alone.

Three more things in here are not obvious.

**Why gobetween and not KubeOne's own Service.** KubeOne can create a Service
for the API endpoint (`cloudProvider.kubevirt.controlPlane.loadBalancer`), but it
cannot set `spec.loadBalancerClass`, and more importantly that Service selects
*pods* - it cannot select control-plane VMs sitting in a kube-ovn subnet.
Setting `apiEndpoint.host` makes KubeOne skip Service creation entirely, so a
kube-ovn native TCP load balancer owns the endpoint instead. It is also the
shape that survives moving the cluster into its own VPC. MetalLB still does the
last hop onto the LAN, but in front of gobetween rather than in front of the
VMs.

**Why the load balancer has a hard-coded backend list.** gobetween needs a static
list of backends, but machine-controller cannot pin a VM's IP - it only ever sets
`ovn.kubernetes.io/logical_switch`, so kube-ovn assigns from the subnet.
`infra/helmfile.yaml` therefore lists the first five usable addresses of
`kubeone-demo-cp` (10.133.0.2-10.133.0.6) and lets gobetween sort out which are
real: its `ping` healthcheck is a **TCP dial** (not ICMP, whatever the chart
README says), so an address with no live apiserver simply never receives
traffic. No pinning, no drift, room to go to `replicas: 3` without touching the
LB. The subnet itself is a `/24` - only those five addresses can ever be
control-plane VMs as far as the LB is concerned, so going past five means
extending the list.

**Why `natOutgoing: true` matters.** A kube-ovn subnet without it has no egress
at all, and kubeadm has to reach registry.k8s.io and the Ubuntu archives. Both
subnets sit in the default VPC (`ovn-cluster`) so they are also routed to
`ovn-default`, which is what lets the gobetween pod reach the control plane.

## Sizing

Default is **1 control plane + 1 worker**, 2 vCPU / 4 GiB / 20 GiB each.

This is a one-node box. `kubev-host-01` carries the control-plane role and runs
the VMs as well, and both StorageClasses (`kubev-main`, `kubev-vms`) are
`rancher.io/local-path` - VM disks are directories on the SNUC's SSD. No
replication overhead, unlike the Longhorn-backed DC environment, but also
nowhere to move a VM to: the disks are `ReadWriteOnce` because local-path
rejects every other access mode, which in turn is why `evictionStrategy:
LiveMigrate` in `kubeone.yaml` has nothing to migrate to today.

To scale: `replicas:` under `controlPlane.nodeSets[0]` or `dynamicWorkers[0]`,
then `just apply`. Three control-plane replicas fit the gobetween backend list
(`10.133.0.2`-`.6` in `infra/helmfile.yaml`) as it stands; past five, extend it.
Watch the SNUC's RAM and SSD - every VM is 4 GiB and 20 GiB of it.

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
