# KubeVirt VMs as a Service via KDP

Exposes KubeVirt Linux (Ubuntu, Flatcar) and Windows VMs, plus the kube-OVN networking
they sit on, as a
self-service offering in the [Kubermatic Developer Platform](https://docs.kubermatic.com/developer-platform/).

A platform user in a KDP workspace applies a `Vpc`, a `Subnet` and a VM, and
gets a running VM on an isolated tenant network. They never touch the service cluster.

## Deployed instance

| | |
| ----------------- | ------------------------------------------------------- |
| KDP               | `platform-demo`, workspace `root:tobi-org`              |
| Service / APIGroup| `kubev.k8c.io`                                          |
| Service cluster   | `kubernetes-kubev` (demo-envs-dc-kubevirt)              |
| Agent namespace   | `kubermatic-virtualization`                             |
| kro namespace     | `kro-system`                                            |
| Egress external   | Subnet `vpc-egress-external` (`172.30.0.0/24`), default VPC |

## How it works

```
root:tobi-org (KDP)                          kubernetes-kubev (service cluster)
-------------------                          ---------------------------------
Service kubev.k8c.io                         kro-system/       kro 0.9.3
  -> APIExport kubev.k8c.io                  kubermatic-virtualization/
  -> APIExportEndpointSlice                    api-syncagent v0.7.0
  -> Secret default/kubev.k8c.io  ----------->  secret kcp-kubeconfig
                                                PublishedResource x4
consumer namespace (e.g. dev)                cluster-scoped/  RGD x4
  Vpc / Subnet / LinuxVirtualMachine <-sync->  kubermatic-virtualization/ synced copies
                                                -> kro -> kubeovn.io Vpc + Subnet
                                                       -> kubevirt.io VirtualMachine
```

1. The KDP `Service` reserves the `kubev.k8c.io` API group and makes KDP generate an
   `APIExport`, an `APIExportEndpointSlice` and the agent kubeconfig.
2. The api-syncagent syncs objects between the workspace and the service cluster, applying
   the naming rules below.
3. kro `ResourceGraphDefinition`s turn each abstract object into real infrastructure and
   feed status back up.

## API

All four kinds are served under `kubev.k8c.io/v1alpha1`:

| Kind                    | Creates                                             |
| ----------------------- | --------------------------------------------------- |
| `Vpc`                   | `kubeovn.io/v1` Vpc                                 |
| `Subnet`                | `kubeovn.io/v1` Subnet                              |
| `LinuxVirtualMachine`   | KubeVirt VM + DataVolume (Ubuntu or Flatcar)        |
| `WindowsVirtualMachine` | KubeVirt VM + LoadBalancer Service (RDP 3389)       |

### Linux: OS and image

`LinuxVirtualMachine` picks the guest with two enums:

| `spec.os` | `spec.image`                                          | Preference | cloud-init          |
| --------- | ----------------------------------------------------- | ---------- | ------------------- |
| `ubuntu`  | `quay.io/kubermatic-virt-disks/ubuntu:24.04-amd64`     | `ubuntu`   | NoCloud cloud-config|
| `ubuntu`  | `quay.io/kubermatic-virt-disks/ubuntu:22.04`           | `ubuntu`   | NoCloud cloud-config|
| `flatcar` | `quay.io/kubermatic-virt-disks/flatcar:4593.2.3-amd64` | `linux`    | ConfigDrive Ignition|

The RGD carries one `VirtualMachine` template per OS, selected with `includeWhen`, because
the two guests need different cloud-init mechanisms - Flatcar is Ignition-only and has no
KubeVirt preference of its own, so it uses the generic `linux` one. Both templates emit the
same object name, so the status wiring is identical either way.

The images are imported from the registry with CDI (`source.registry`), not fetched over
HTTP, so adding a value means adding a tag that exists in
[quay.io/kubermatic-virt-disks](https://quay.io/organization/kubermatic-virt-disks).

**`os` and `image` are two independent dropdowns, not a cascade.** KDP's form has no way to
filter one field by another field's value (see *Dropdowns* below), so picking `os: flatcar`
with an `ubuntu:*` image is accepted by the API server and simply boots Ubuntu with the
wrong preference. The field descriptions spell out the pairing.

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
`10.96.0.10`, `apt` cannot resolve, and the guest agent install fails silently.

### Mistyping a subnet blocks the VM instead of half-creating it

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

### Outbound: why a custom VPC needs an egress gateway

A custom kube-OVN VPC has **no outbound path at all** out of the box. Two things that look
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

### Inbound: the LoadBalancer IP

The Service gets a public IP, but KubeLB's last hop is `nodeIP:nodePort`, which reaches VMs
on `ovn-default` and not VMs inside a custom VPC. The Service and its endpoint are correct
in-cluster; the public path is a known infrastructure gap, not an error in this RGD.

### Instance types

Both VM kinds pick their size from a `VirtualMachineClusterInstancetype`, constrained by an
`enum` in the schema so the dashboard renders a dropdown and the API server rejects anything
else. Only `u1.*` types are offered: `cx1`/`m1`/`n1`/`rt1` need cpumanager or hugepages and
land in `ErrorUnschedulable` on these nodes.

| Kind                    | Allowed instance types                        | Default     |
| ----------------------- | --------------------------------------------- | ----------- |
| `LinuxVirtualMachine`   | all 10 `u1.*`, from `u1.nano` to `u1.8xlarge`  | `u1.medium` |
| `WindowsVirtualMachine` | `u1.large` and larger (5 types)                | `u1.large`  |

`WindowsVirtualMachine.spec.templateImageName` is likewise an enum; `windows-10-golden` is
the only golden image PVC on the cluster today. Add values to the enum in the RGD as more
golden images appear.

### Disk size on `WindowsVirtualMachine`

`spec.diskSize` is an enum (`50Gi`, `100Gi`, `200Gi`) rather than a free-form string, because
the Windows kind *clones* the `windows-10-golden` PVC and **a CDI clone can grow but never
shrink**. A target smaller than the 50Gi source is rejected by CDI with
`CloneValidationFailed`, and CDI then goes completely silent: it writes no DataVolume phase,
creates no target PVC and emits no Event, so the VM sits `Stopped` forever with nothing
pointing at the cause. Keep the smallest enum value at or above the golden image PVC size,
and widen the enum when a larger golden image is added.

The Linux kind keeps a free-form `diskSize` on purpose - it imports from a registry rather
than cloning a PVC, so any size at or above the image is valid there.

Because a KubeVirt VM may not set an instance type *and* explicit cpu/memory, the Linux kind
does not take `cpu`/`memory` - it takes `instanceType` and a preference chosen by `spec.os`.

### Dropdowns in the KDP UI

The create form is [react-jsonschema-form] driven entirely by the CRD's OpenAPI v3 schema, so
a schema `enum` becomes a `<select>` with no extra work. That covers `os`, `image` and
`instanceType`, plus `templateImageName` and `loadBalancerClass` on
`WindowsVirtualMachine`.

For a list that is only known at runtime - which VPCs and Subnets exist *in this workspace* -
KDP reads a `kdp:options` block out of the field's `description` and turns the field into a
live, server-backed dropdown:

```yaml
vpc: |-
  string | description="Vpc in this workspace to attach to.
  <!-- kdp:options
  apiVersion: options.kdp.k8c.io/v1
  kind: FieldSource
  source: local                              # or vwcatalog, for the service catalog
  path: /apis/kubev.k8c.io/v1alpha1/vpcs     # must start with /
  value: .metadata.name
  -->"
```

The dashboard is supposed to GET `clusters/<workspace><path>`, walk `.items`, evaluate
`value` against each one, and rewrite the field to a `oneOf` of the names it found.

**On platform-demo today the last step is broken.** Everything up to it works: the field
does render as a dropdown, the request fires against the right URL and returns 200. But the
list contains a single entry that is the literal `value` expression rather than the object
names. Setting `value: .metadata.uid` produces an option labelled `.metadata.uid`, which
confirms the expression is passed through instead of evaluated. So the dropdown is there but
not yet usable, and `vpc`/`subnet` still have to be typed by hand. The blocks are left in
place because they cost nothing and will start working when the dashboard is fixed.

Other constraints worth knowing:

- Only `string`, `integer`, `number` fields and arrays of those.
- `path` may interpolate `${LOCAL_WORKSPACE}`, `${APIEXPORT_WORKSPACE}` and
  `${LOCAL_NAMESPACE}` - **but not other form fields**, which is why `os` cannot filter
  `image`.
- The YAML block must be `|-` in the RGD, not `|`. kro's marker parser treats the trailing
  newline a `|` leaves behind as the start of a new marker and fails the whole RGD with
  `marker key '' without a value`.
- It degrades gracefully: `kubectl` users just see the block as part of the description, and
  the field stays a plain string in the schema.

An alternative for UI-only tweaks is KDP's built-in
[UI builder](https://platform-demo.lab.kubermatic.io/organizations/tobi-org/services/kubev.k8c.io/ui-builder),
which stores a per-view `ui-config-*` ConfigMap (`create-form`, `detail-view`, `list-view`)
in KDP; `Service.spec.generateUI: true` makes KDP generate one automatically. It is the
better tool for layout and labels, and the pragmatic place to fix the VPC/Subnet pickers
while `kdp:options` is broken. The schema-side approach is used here because it lives in the
RGD, so it is versioned with the service and applies to every consumer of the API, not just
the dashboard.

### Field labels and acronym casing

When a schema property carries no `title`, the dashboard derives the label from the property
name, and its title-caser knows nothing about acronyms. That turned `os` into "Os",
`sshPublicKey` into "Ssh Public Key" and `vpc` into "Vpc". The detail view uses a second,
more aggressive caser that also produced "Load Balancer I P" and "V4available I Prange".

Both honour an explicit `title` and only fall back to the property name without one:

```ts
// lib/apis/service-objects/requests.ts          - create form
if (!property.title) property.title = toTitleCase(key);
// components/service-object/detail/...          - detail view
const label = schema?.title || toTitleCase(key);
```

**kro cannot emit a `title`.** Its simple-schema marker allowlist
(`pkg/simpleschema/markers.go`, `markerTypeFromString`) is `required`, `default`,
`description`, `minimum`, `maximum`, `validation`, `enum`, `immutable`, `pattern`,
`uniqueItems`, `minLength`, `maxLength`, `minItems`, `maxItems`, `listType`, `listMapKey`.
There is no `title=` in v0.9.3 or on kro `main`, and an unknown marker makes kro reject the
whole RGD. So the titles are painted onto the CRDs kro generated, as RFC 6902 JSON Patches:

| File                                    | CRD                                   |
| --------------------------------------- | ------------------------------------- |
| `linux/crd-titles.yaml`                 | `linuxvirtualmachines.kubev.k8c.io`   |
| `windows/crd-titles.yaml`               | `windowsvirtualmachines.kubev.k8c.io` |
| `vpc-networking/crd-titles-vpc.yaml`    | `vpcs.kubev.k8c.io`                   |
| `vpc-networking/crd-titles-subnet.yaml` | `subnets.kubev.k8c.io`                |

`just sc-titles` applies all four, and `sc-rgds` chains it automatically.

**Why the patch sticks.** kro only updates an existing CRD when `pkg/graph/crd/compat`
reports a change, and that comparator never looks at `Title` - so in steady state kro sees
"no changes" and skips the write entirely. The one case that does lose the titles is a real
RGD change: kro then sends a JSON *merge* patch of the desired CRD, and because
`spec.versions` is a list a merge patch replaces it wholesale. That is exactly why `sc-rgds`
runs `sc-titles` after it. You can watch it happen - after an RGD edit the two untouched
CRDs report `patched (no change)` while the edited ones report `patched`.

Run `just sc-agent-restart` afterwards so the agent publishes a fresh `APIResourceSchema`
carrying the titles. Verify against the document the dashboard actually consumes:

```bash
KUBECONFIG=../kdp-demo-kubeconfig kubectl get --raw \
  /openapi/v3/apis/kubev.k8c.io/v1alpha1 | jq '
  .components.schemas | to_entries[]
  | select(.key | endswith(".LinuxVirtualMachine"))
  | .value.properties.spec.properties | map_values(.title)'
```

A stale `ui-config-*` ConfigMap from the UI builder does not shadow this. The dashboard
stores a hash of the schema on the ConfigMap and falls back to the schema-driven form when
it no longer matches, so adding titles marks any generated form outdated by construction.

[react-jsonschema-form]: https://rjsf-team.github.io/react-jsonschema-form/

## Naming

kube-OVN `Vpc` and `Subnet` are cluster-scoped, so a VPC is workspace-global rather than
per-namespace. Objects are renamed on the way down:

```
Vpc / Subnet : kdp-{{ .ClusterName }}-{{ .Object.metadata.name }}
VMs          : kdp-{{ .ClusterName }}-{{ .Object.metadata.namespace }}-{{ .Object.metadata.name }}
```

The `kdp-` prefix is not cosmetic: kube-OVN enforces `^[^0-9]` on Subnet names and kcp
cluster names often start with a digit. The cluster hash keeps these clear of the VPCs
KubeV manages itself and of the VMs already running in `kubermatic-virtualization`.

A consequence: **VPC and Subnet names must be unique within a workspace**, and a VM must
reference a VPC and Subnet from its own workspace.

## Usage

Targets are prefixed by the side they touch, so `just --list` groups them:

| prefix  | side                                                     |
| ------- | -------------------------------------------------------- |
| `kdp-`  | the KDP/kcp workspace that offers the service             |
| `sc-`   | the service cluster that runs the VMs                     |
| `demo-` | consumer objects, applied the way a platform user would   |
| `show-` | read-only inspection                                      |
| (none)  | whole lifecycle: `preflight`, `deploy`, `clean`           |

```bash
just                            # list targets, grouped by side
just preflight                  # check both clusters before changing anything
just deploy                     # kro -> KDP Service -> agent -> RGDs -> PublishedResources
just kdp-bind                   # bind the service into the workspace
just demo-linux                 # apply the Linux example
just demo-windows               # apply the Windows example
just show-status                # both sides at a glance
just show-consumer              # what the platform user sees, incl. Ready conditions
just show-agent-logs            # or: just show-kro-logs
just clean                      # remove the service (leaves kro and pre-existing VMs)
just kdp-logo <image> [size]    # regenerate the catalog logo and push it
just kdp-publish                # let other orgs see and bind the service
```

## Publishing to other organizations

The service catalog wildcard-lists Services across every provider workspace and then decides
per object what the caller may see, using ordinary RBAC **in the provider workspace**. Two
grants, doing different jobs:

| grant                     | effect                                                          |
| ------------------------- | --------------------------------------------------------------- |
| `get` on the Service      | the tile appears in another org's catalog, in full               |
| `catalog` on the Service  | tile appears with name and labels only - no spec, browse-only    |
| `bind` on the APIExport   | the other org may actually create an APIBinding and use the kinds |

`kdp/public-rbac.yaml` grants `get` + `bind` to `system:authenticated`, i.e. every org on the
installation. `just kdp-publish` applies it, `just kdp-unpublish` revokes it.

Multi-tenancy on the naming side is already handled: every PublishedResource prefixes
objects with `kdp-{{ .ClusterName }}-`, so two orgs creating a VPC of the same name do not
collide. What is **not** isolated is the service cluster - every org's VMs land in the single
`kubermatic-virtualization` namespace and share its quota and storage.

`deploy` chains `sc-kro kdp-service sc-agent-secret sc-agent sc-rgds sc-publish`, ordered so
that missing prerequisites surface early. `sc-agent-restart` picks up a changed
PublishedResource without a full redeploy.

## Layout

```
Justfile                          all operations
kdp/service.yaml                  the KDP Service (reserves the API group)
kdp/logo.png                      catalog logo artwork
kdp/logo-configmap.yaml           logo as a data URI (generated)
kdp/render-logo.sh                regenerates both from a source image
service-cluster/
  vpc-egress-external.yaml        cluster-wide external net for the egress gateways
  syncagent-values.yaml           helm values for the api-syncagent
  rbac.yaml                       agent RBAC, incl. the Role the chart forgets
  kro-rbac.yaml                   kro access to the groups these RGDs touch
vpc-networking/                   Vpc + Subnet RGDs and PublishedResources
linux/                            Linux VM RGD, PublishedResource, example
windows/                          Windows VM RGD, PublishedResource, example
*/crd-titles*.yaml                JSON Patches adding OpenAPI titles to the generated
                                  CRDs, so the dashboard shows OS / VPC / SSH Public Key
architecture/                     presentation diagram
```

## Prerequisites on the service cluster

KubeVirt, CDI, kube-OVN, a `kubev-vms` StorageClass, and for Windows a golden image PVC
named by `spec.templateImageName` in `kubermatic-virtualization`. `just preflight` checks
all of them. kro is installed by `just sc-kro`.

## Notes and gotchas

- **`spec.kubeconfig` is required on the Service.** Without it KDP never generates an agent
  kubeconfig, and the only Secret you get is the internal key in `kcp-system`.
- **The helm chart binds a leaderelection Role it does not create** (through chart 0.6.2).
  `service-cluster/rbac.yaml` supplies it, and `just sc-agent` applies RBAC first.
- **The Deployment is named after the helm release** (`kubev-vms`); only the ServiceAccount
  carries the `-api-syncagent` suffix.
- **kro ships RBAC for its own CRDs only.** `kro-rbac.yaml` grants the rest.
- **`virtualization.k8c.io` belongs to the KubeV product.** Vpc and Subnet therefore live in
  `kubev.k8c.io`, which also removes the need for a `projection` in the PublishedResources.
- **Changing an RGD schema by removing a field needs the CRD recreated.** kro refuses with
  `breaking changes detected: Property x was removed`, and deleting the RGD alone does not
  drop the CRD. Delete the CRD too, after confirming no instances remain.
- **Do not strip `status.conditions` in a PublishedResource mutation.** The dashboard reads
  `status.conditions[Ready]` to draw the Ready dot in the service catalog; deleting it makes
  the UI show "No condition data" for that kind while everything is in fact healthy.
- **The Windows golden image is cloned same-namespace, Block to Block.** A filesystem target
  fails the clone on `lost+found`.
