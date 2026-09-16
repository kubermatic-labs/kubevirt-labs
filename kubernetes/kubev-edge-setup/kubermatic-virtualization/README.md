# KubeV Cluster Setup

This directory contains an example `Justfile` for managing a Kubermatic Virtualization (KubeV) cluster (example: `kubev`).

## Requirements

Before starting, verify your infrastructure meets the hardware and software requirements:
- [KubeV Requirements](https://docs.kubermatic.com/kubermatic-virtualization/main/architecture/requirements/)

## Prepare Configuration

### Print Full Config Template

Generate a full example configuration to understand all available options:

```bash
kubermatic-virtualization config print --full
```

See [Declarative Installation Docs](https://docs.kubermatic.com/kubermatic-virtualization/main/installation/declarative-installation/) for details.

Edit your cluster config at `kubev/kubev.yaml`.

### Interactive Installation (alternative)

Alternatively, use the interactive installer to generate a config:

```bash
kubermatic-virtualization install
```

See [Interactive Installation Docs](https://docs.kubermatic.com/kubermatic-virtualization/main/installation/interactive-installation/).

## Setup Steps

### 1. Start Local KubeV Tooling Container

```bash
just local-kubev-tooling-start
```

Re-attach to a running container:

```bash
just local-kubev-tooling-exec
```

Remove the container:

```bash
just local-kubev-tooling-rm
```

### 2. Load SSH Key & Environment

Starts an ssh-agent if none is reachable and adds the deployment key `../.local/id_rsa`.
The Terraform recipes below depend on it, so running it by hand is optional:

```bash
just env-prepare
```

### 3. Provision Load Balancer (Terraform)

```bash
just kubev-lb-tf-init
just kubev-lb-tf-apply
just kubev-lb-output
```

### 4. Apply KubeV Cluster

Runs `kubermatic-virtualization apply`, copies the kubeconfig, untaints control-plane nodes, syncs
Helm releases, and publishes the dashboard on the LAN:

```bash
just kubev-apply
```

Individual steps:

```bash
just untaint-cp-nodes        # remove control-plane taints
just kubev-apply-services    # helmfile sync
just allow-cp-node-lb        # let MetalLB announce from the control-plane node
just kubev-expose-dashboard  # extra type=LoadBalancer Service for the UI
```

### 5. Expose the Dashboard on the LAN

The installer renders `svc/kubev-dashboard` as ClusterIP only, and the KubeV config schema has no
knob for its Service type. `kubev/dashboard-svc-lb.yaml` therefore adds a **second**, standalone
`type: LoadBalancer` Service alongside it - the Helm release itself is never touched:

```bash
just kubev-expose-dashboard
```

| Item         | Value                                                                      |
|--------------|----------------------------------------------------------------------------|
| URL          | <http://10.77.33.20/> (also on `:8080`)                                    |
| Credentials  | `kubev-basic-auth-credentials` - user `admin`, password generated on apply |
| Announcement | MetalLB **L2 / ARP**, from `loadBalancer.metallb.ipRange` in `kubev.yaml`  |
| IP           | pinned with `metallb.io/loadBalancerIPs`, first of `10.77.33.20-.50`       |

One origin is enough: the dashboard's nginx proxies `/api/` and `/auth/` to `kubev-api-server` on
the same port, so the API server must **not** be exposed separately. Login is basic auth enforced
by the API server (24h session cookie, `cookieSecure: false`), which means plain HTTP works - and
also that the UI is reachable by anyone on the edge LAN without TLS. Keep that LAN trusted.

The MetalLB pool sits below the k8c-edge router's DHCP range (`10.77.33.100-.199`), so nothing on
the LAN can hand out the same address.

**ARP, not BGP, on purpose.** The dashboard VIP is in `10.77.33.0/24`, the same broadcast domain as
its clients, so answering ARP is all that is needed and it works with no router-side configuration
at all. The cluster currently has exactly one `L2Advertisement` and no `BGPPeer` - verify with
`kubectl get bgppeers,bgpadvertisements -A`. A second, *routed* path is prepared but not applied:
`kubev/.todo/metallb-bgp` peers the speaker with the Chateau (AS 64513 <-> 64512) and advertises the
separate `10.77.34.0/24` pool, with the router half driven by `just bgp-apply` in `../edge-network`.
That pool is `autoAssign: false`, so applying it changes nothing here - a Service opts in with
`metallb.io/address-pool: bgp-pool`. Leave the dashboard on the L2 pool unless its clients move off
this LAN; BGP buys reachability from *other* subnets, not from this one.

To confirm an IP is really being *announced* rather than merely allocated:

```bash
just kubev-lb-status
```

> **Gotcha - LoadBalancer allocated but unreachable.** kubeadm labels control-plane nodes
> `node.kubernetes.io/exclude-from-external-load-balancers`, and MetalLB honours it.
> `just untaint-cp-nodes` removes the *taints* so workloads land on this single-node box, but the
> *label* survives, and the speaker then reports `"no available nodes"`: `EXTERNAL-IP` looks
> correct while `arp -n <vip>` stays `incomplete` and every connection times out.
> `just allow-cp-node-lb` removes the label, and `kubev-expose-dashboard` depends on that recipe,
> so `just kubev-apply` now takes care of it.

## Environment

The tooling container image lives in the `Justfile` and can be overridden per invocation through
the environment:

```bash
TOOLING_CONTAINER_TAG=kubev-v1.3.0 just local-kubev-tooling-start
DOCKER_REPO=my.registry/kubermatic-virtualization-tooling just local-kubev-tooling-start
```

The KubeV UI / registry credentials stay out of git, in `../.local/kubev.env`:

```bash
KUBEV_USERNAME=...
KUBEV_PASSWORD=...
```

`just` loads that file (`set dotenv-path`) for **every** recipe, so `KUBEV_USERNAME` and
`KUBEV_PASSWORD` are in place for `kubermatic-virtualization` and `helmfile` alike.
`local-kubev-tooling-start` additionally passes it to `docker run` as an `--env-file`, so the
credentials are present inside the tooling container too. The file is untracked; if it is missing
the recipes still run and the variables are simply unset.

## Key Files

| Path                                | Description                                                      |
|-------------------------------------|------------------------------------------------------------------|
| `kubev/kubev.yaml`                  | KubeV cluster configuration                                      |
| `kubev/kubev-kubeconfig.crypt.yaml` | Encrypted kubeconfig (written after apply)                       |
| `../.local/id_rsa`                  | SSH key for cluster access                                       |
| `../.local/kubev.env`               | KubeV UI credentials (untracked, auto-loaded)                    |
| `kubev/dashboard-svc-lb.yaml`       | Extra `type: LoadBalancer` Service exposing the UI (MetalLB/ARP) |
| `kubev-basic-auth-credentials`      | Dashboard basic-auth login (untracked, written on apply)         |
