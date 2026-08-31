# Demo Setup - Bastion VM

A dedicated **bastion VM** (`tobi-demo-bastion`) on the demo cluster: reachable box with
`netbird`, `tailscale` and `docker`, demo state on a 50G `/data` disk (OS disk disposable).

Two things differ from a plain KubeVirt VM:

1. **Cloud-init lives in a Secret** - KubeVirt caps inline `cloudInitNoCloud.userData` at
   **2048 bytes**; this bootstrap is ~4.2 kB.
2. **Access is by IP**, not a `virtctl` tunnel. Intended path is the public IP
   `34.159.197.234`, but that KubeLB hop is broken (parked, below) - **use `just ssh-ts`**.

## Prerequisites

`kubectl` on `PATH` (`virtctl` only for the console fallback) and `demo.env` (gitignored)
with `KUBECONFIG_KUBEV` + `KUBECONFIG_ROUTING_CLUSTER`.

## Files

| File | Purpose |
|---|---|
| `justfile`                            | Demo helper wrapping `deploy.sh` |
| `bastion-vm.yaml`                     | KubeVirt `VirtualMachine` - dataVolumeTemplates, pinned ovn IP, cloud-init `secretRef` |
| `cloudinit/bastion-user-data.sh`      | Bootstrap - plain bash, shellcheck-able, no size limit |
| `deploy.sh`                           | `cloudinit` / `apply` / `status` / `endpoints` / `destroy` |
| `demo.env`                            | kubeconfigs, IPs, SSH user (gitignored) |
| `routing-cluster/bastion-svc-lb.yaml` | LoadBalancer + manual Endpoints on the KKP routing cluster |
| `tailscale-routing.local.md`          | Manual steps to make the VM a tailnet subnet router (gitignored) |

## Deploy

```bash
cd hack/demo-setup
just              # list recipes
just apply        # Secret -> VM -> wait Ready -> wire LB endpoints -> print SSH
just status       # VM state + pinned IP + public IP + endpoint health
just watch        # follow vm/vmi/po/pvc
```

## Connect

```bash
just ssh-ts                                       # WORKS TODAY - Tailscale, ubuntu@100.96.207.39
ssh ubuntu@tobi-demo-bastion.tailbf56ad.ts.net    # MagicDNS
just ssh                                          # public IP 34.159.197.234 - currently broken
just ssh-jump                                     # socat jump pod in the seed - no tailnet needed
just console                                      # serial console, last resort
```

> The key `id_rsa_loodse` lives **only in your ssh-agent**, not on disk. `BASTION_SSH_KEY`
> in `demo.env` is deliberately empty so no `-i` is passed. Set it only to force a key file.

> **virtctl must match the server** (KubeVirt **v1.6.5**); a newer brew `virtctl` breaks the
> console tunnel.

## Cloud-init is a Secret

```
cloudinit/bastion-user-data.sh
   │  just cloudinit   (kubectl create secret generic --from-file=userData=...)
   ▼
secret/tobi-demo-bastion-cloudinit  (key: userData)
   │  bastion-vm.yaml: cloudInitNoCloud.secretRef.name
   ▼
tobi-demo-bastion /dev/vdc  (NoCloud datasource)
```

> **YAML gotcha**: the Go field is `UserDataSecretRef` but the **YAML key is `secretRef`**.

Cloud-init user-data runs **per-instance**, so a reboot does *not* re-run it. After editing:

```bash
just cloudinit && just recreate    # fresh instance -> cloud-init runs again
```

Key rotation needs no recreate - the public key is inline in the bootstrap (marked
`ROTATE HERE`), or append over an open session:

```bash
just ssh-ts 'cat >> ~/.ssh/authorized_keys' < ~/.ssh/new_key.pub
```

## Why the VM IP is pinned

`svc/bastion-vm` on the routing cluster is **selector-less** (the VM is not a pod there) and
paired with a hand-written `Endpoints` object that hard-codes the address - an
auto-allocated IP would go stale on every recreate and SSH would break silently. So:

```yaml
ovn.kubernetes.io/ip_address: 172.16.15.255
```

Kyverno (`enforce-vm-vpc-namespace-slice`) freezes `logical_router` / `logical_switch` after
creation but not `ip_address`, so this is allowed; kube-ovn's `--keep-vm-ip=true` also
survives reboots and live migration. If it ever drifts, `just publish` re-patches the
Endpoints and warns you.

## Parked: KubeLB's public path is broken for the WHOLE routing cluster

> **Parked 2026-08-31.** Recorded in-cluster as annotations on `svc/bastion-vm`
> (`demo.k8c.io/known-issue`, `-status`, `-workaround`). Use Tailscale meanwhile.

`ssh ubuntu@34.159.197.234` -> `kex_exchange_identification: read: Connection reset by peer`.

**Not a NetworkPolicy and not the selector-less Endpoints.** Ruled out on both clusters:
no `NetworkPolicy` anywhere, no Calico `GlobalNetworkPolicy`/`HostEndpoint`, no kube-ovn
security groups or subnet ACLs (`ovn-default` is `private: false`).

The decisive test was a **control service** - plain nginx Pod, normal selector-based
LoadBalancer, same namespace:

| Backend | in-cluster | via KubeLB public IP |
|---|---|---|
| `bastion-vm` (manual Endpoints) | `172.16.15.255:22` open | RST at kex |
| `kubelb-probe` (real nginx pod) | clusterIP + nodePort -> 200 | RST, 0 bytes, 0.02s |

Both are healthy from inside and both die at the KubeLB edge, so the fault is KubeLB's data
path into this cluster. TCP accepted then RST with zero bytes in ~20 ms is an L4 proxy
failing its *upstream* connect: KubeLB routes to the tenant's `nodeIP:nodePort`, and this
tenant's only node `tobi-demo-router` is at **172.16.16.7** - a private kube-ovn address a
KubeLB envoy in the GCP fog cluster cannot route to.

Confirming needs the KubeLB management ("fog") cluster; its kubeconfig is not on this
machine.

## Manual, NOT provisioned

Both survive only until the next `just recreate`.

**Mesh clients (skip-auth).** Cloud-init installs `netbird` + `tailscale` but runs neither
`up` - each needs an interactive browser/SSO login. Tailscale is currently logged in
(`100.96.207.39`); NetBird is installed but `NeedsLogin`.

```bash
sudo tailscale up      # prints a login URL
netbird up             # browser/device auth flow
```

**Demo user `nico`** - exists on the running VM (sudo + docker + password login), but no
user, password or hash lives in this repo. Cloud-init sets `PasswordAuthentication no`
globally, so re-add by hand:

```bash
sudo useradd -m -s /bin/bash -G sudo,docker nico
sudo passwd nico

# password login for nico ONLY - the box stays key-only for everyone else.
# `Match all` is load-bearing: this drop-in is included near the TOP of sshd_config,
# so without it the Match block stays open and scopes every later global directive to nico.
sudo tee /etc/ssh/sshd_config.d/98-nico.conf >/dev/null <<'EOF'
Match User nico
    PasswordAuthentication yes
Match all
EOF
sudo sshd -t && sudo systemctl reload ssh

echo 'nico ALL=(ALL) NOPASSWD:ALL' | sudo EDITOR=tee visudo -f /etc/sudoers.d/nico
sudo chmod 0440 /etc/sudoers.d/nico    # visudo leaves 0640; sudo rejects that
```

Verify: `sudo sshd -T -C user=nico | grep passwordauth` -> `yes`, `-C user=ubuntu` -> `no`.

## Sanity checks

```bash
just status                    # pinned IP == live IP, LB IP present, endpoints match
just cloudinit-log             # proves the Secret was consumed
just ssh-ts 'df -h /data; lsblk; ip -br a'    # 50G mount, enp1s0 == 172.16.15.255
```

## Tear down

```bash
just destroy      # VM + PVCs + cloud-init Secret
```

Deliberately leaves `svc/bastion-vm` alone - deleting it releases the public IP and KubeLB
hands out a different one. After recreating, run `just publish` (or `just apply`).

## Notes

- Root disk 15G from `quay.io/kubermatic-virt-disks/ubuntu:24.04-amd64`; data disk 50G blank,
  ext4, mounted at `/data` by UUID. Both on storage class `kubev-vms`.
- Data disk needs `source: { blank: {} }` - a source-less DataVolume stays Pending.
- NIC is on the **default pod network** (`ovn-default`, `172.16.0.0/16`) via plain
  `ovn.kubernetes.io/logical_switch` + `ip_address` annotations and a `bridge` interface on
  `pod: {}` - no multus NAD.
- An earlier revision used a multus NAD (`kubermatic-virtualization-workload-a-sn`,
  `10.0.166.0/24`), but VMs on that isolated VPC subnet were **not** reachable from the
  cluster plane. Since KubeVirt/Kyverno forbid patching `ovn.kubernetes.io/logical_*` in
  place, the move to `ovn-default` used `kubectl delete vm --cascade=orphan` so the PVCs
  survived and were re-referenced.
- The bastion answers on a **public** IP, so cloud-init disables password and
  keyboard-interactive auth. Key-only.
- `v1 Endpoints` is deprecated in k8s 1.33+ (routing cluster is 1.34) but still honoured. If
  you migrate to a hand-written `discovery.k8s.io/v1` EndpointSlice, delete the `Endpoints`
  object in the same change - running both invites the EndpointSliceMirroring controller to
  fight you.
