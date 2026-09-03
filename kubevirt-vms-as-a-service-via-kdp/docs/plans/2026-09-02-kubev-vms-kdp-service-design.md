# KubeVirt VMs as a Service via KDP - deployment design

Date: 2026-09-02
Target platform: KDP `platform-demo`, organization workspace `root:tobi-org`
Target service cluster: `kubernetes-kubev` (demo-envs-dc-kubevirt)
Status: deployed and verified end to end

## Goal

Publish the existing `kubevirt-vms-as-a-service-via-kdp` resources as a real, reproducible
KDP service so a platform user in `root:tobi-org` can apply a Vpc, a Subnet and a VM and
get a running KubeVirt VM on the service cluster.

## Decisions

| Topic          | Decision                                                              |
| -------------- | --------------------------------------------------------------------- |
| API group      | One KDP Service reserving `kubev.k8c.io`; all four kinds live in it    |
| Sync target ns | All synced objects land in `kubermatic-virtualization`                 |
| kro            | v0.9.3, installed by the Justfile into its own `kro-system` namespace  |
| Scope          | Full: Vpc, Subnet, LinuxVirtualMachine, WindowsVirtualMachine          |

## Why one API group

`Service.spec.apiGroup` in `core.kdp.k8c.io/v1alpha1` is a single required string, so one
Service reserves exactly one API group. The repo previously used two groups. Two would mean
two Services, two APIExports and two api-syncagent deployments, because a Service must be
served by exactly one agent.

The original plan was to keep `Vpc` and `Subnet` in `virtualization.k8c.io` and use
`projection.group` to expose them as `kubev.k8c.io`. That turned out to be impossible:
`vpcs.virtualization.k8c.io` and `subnets.virtualization.k8c.io` are CRDs owned by the
KubeVirtualization product itself on this cluster, and kro refuses to adopt a CRD it does
not own. Moving the RGDs to `kubev.k8c.io` avoids the collision and removes the need for a
projection entirely.

## Architecture

```
root:tobi-org (KDP)                          kubernetes-kubev (service cluster)
-------------------                          ---------------------------------
Service kubev.k8c.io                         kro-system/       kro 0.9.3
  -> APIExport kubev.k8c.io                  kubermatic-virtualization/
  -> APIExportEndpointSlice                    api-syncagent v0.7.0 (chart 0.6.2)
  -> Secret default/kubev.k8c.io  ----------->  secret kcp-kubeconfig
                                                PublishedResource x4
consumer namespace                           cluster-scoped/  RGD x4
  Vpc / Subnet / LinuxVirtualMachine <-sync->  kubermatic-virtualization/ synced copies
                                                -> kro -> kubeovn.io Vpc + Subnet
                                                       -> kubevirt.io VirtualMachine
```

## Naming

kube-OVN `Vpc` and `Subnet` are cluster-scoped, so VPCs are workspace-global:

```
Vpc / Subnet : kdp-{{ .ClusterName }}-{{ .Object.metadata.name }}
VMs          : kdp-{{ .ClusterName }}-{{ .Object.metadata.namespace }}-{{ .Object.metadata.name }}
```

The `kdp-` prefix is required, not cosmetic: kube-OVN validates Subnet names against
`^[^0-9]` and the kcp cluster name here is `10p3s8dupeeavcyy`. The cluster hash keeps these
names clear of the VPCs KubeV manages (`kubermatic-virtualization-demo-vpc`) and of the VMs
already running in `kubermatic-virtualization`.

Cross-references have to be reconstructed with the same prefix, because a consumer only ever
writes the short name. Both the Subnet RGD's `vpc` field and the VM RGDs' OVN annotations
build it from the `syncagent.kcp.io/remote-object-cluster` label, which is the only piece of
provenance available as a label (the original namespace is exposed only as an annotation).

## Changes to the existing resources

1. api-syncagent v0.3.0 -> v0.7.0. `apiExportName` was replaced by
   `apiExportEndpointSliceName`.
2. PublishedResource `spec.resource.version` is deprecated -> `versions: [v1alpha1]`.
3. RBAC bound the agent ServiceAccount in `kcp-system` -> `kubermatic-virtualization`, and
   was reshaped into KDP's aggregated-ClusterRole convention.
4. The RGD `status` blocks used an OpenAPI-style `type:`/`properties:` tree. kro 0.9.3
   requires plain `field: ${expression}` pairs, and printer columns must point at
   `.status.<field>` rather than `.status.properties.<field>.expression`.
5. The VM RGDs built the OVN annotation as `${spec.vpc}-${cluster}`, which never matched the
   object kro creates. Now `kdp-${cluster}-${spec.vpc}`.
6. The Windows RGD cloned a DataSource in `build-vm-win10`, a namespace that does not exist.
   The golden image PVC actually lives in `kubermatic-virtualization`, so it is now a
   same-namespace `source.pvc` clone with `volumeMode: Block`. That also made the
   cross-namespace CDI clone ClusterRole and RoleBinding unnecessary.
7. kube-OVN Vpc and Subnet are cluster-scoped; the RGD templates no longer set a namespace.
8. Both VM PublishedResources carried a `mutation.status.delete` on `status.conditions`.
   kro sets a `Ready` condition on every instance and the KDP dashboard reads it to render
   the Ready dot, so stripping it made the catalog show "No condition data" for the two VM
   kinds while Vpc and Subnet - which had no such mutation - showed green. Mutation removed.

## Instance types and images as dropdowns

kro v0.9.3 supports an `enum` marker in the simple schema (markers are space separated after
a single `|`), and it lands verbatim in the generated CRD's `openAPIV3Schema`, so the
dashboard renders a dropdown and the API server enforces the values:

```yaml
instanceType: string | enum="u1.large,u1.xlarge" default="u1.large" description="VM size"
```

Ubuntu offers all 10 `u1.*` types, Windows only `u1.large` and larger. Only `u1.*` is
offered because `cx1`/`m1`/`n1`/`rt1` require cpumanager or hugepages and go
`ErrorUnschedulable` on these nodes - the enum now makes that failure unreachable.

Switching Ubuntu to an instance type meant dropping its `cpu` and `memory` fields, because
KubeVirt rejects a VM that sets both. kro refuses to remove a property from a live CRD, and
deleting the RGD does not delete the CRD, so the CRD had to be deleted explicitly once no
instances remained.

## Things that were not obvious

- **`Service.spec.kubeconfig` must be set by the author.** Without it KDP creates only an
  internal key Secret in `kcp-system` and never generates an agent kubeconfig.
- **The helm chart creates Role `<release>:leaderelection` but binds
  `<release>-api-syncagent:leaderelection`.** The agent cannot elect a leader until the
  missing Role is supplied. The chart's events Role is not created in this namespace either.
- **The chart names the Deployment after the release**, not `<release>-api-syncagent`.
- **kro ships RBAC for its own CRDs only.** It needs explicit access to the instance CRDs
  and to everything the RGDs create, or its controllers fail with a cache sync timeout.

## Verification

Applied `ubuntu/example.yaml` in `root:tobi-org`. The objects synced down, kro created the
kube-OVN Vpc and Subnet and a KubeVirt VM, the disk imported to 100%, and the VM reached
Running with IP `10.0.0.2` from the tenant subnet. Status propagated back so the platform
user sees `Running` and the IP on their own object. Deleting the consumer objects removed
the synced copies and the underlying infrastructure.

All four kinds report `status.conditions` to the dashboard, so the service catalog renders a
real Ready state for each object rather than "No condition data".

The Windows path was verified too: the 50Gi Block to Block clone completed and the VM reached
Running on `10.44.0.2` with its RDP LoadBalancer service. After the instance-type change the
Ubuntu VM came back up as `u1.large` (2 vCPU / 8Gi, `ubuntu` preference) on `10.0.0.3`.

The catalog entry carries a logo, supplied as a data URI in ConfigMap
`default/kubev.k8c.io-logo` and referenced from `catalogMetadata.logo.configMap`.

## Risks

- kro is a new cluster-wide operator on a cluster running live demo VMs. It acts only on its
  own CRDs, and nothing here mutates the pre-existing VMs or VPCs.
- The agent and the synced VMs share `kubermatic-virtualization` with the KubeV product.
  Name collisions are prevented by the `kdp-<cluster>` prefix.

---

## Addendum, 2026-09-03

### `VirtualMachine` renamed to `LinuxVirtualMachine`

The Ubuntu-only kind became a two-OS kind. `spec.os` (`ubuntu` | `flatcar`) selects the
KubeVirt preference and the cloud-init mechanism, `spec.image` selects the container disk.
The RGD carries one VM template per OS behind `includeWhen`, both emitting the same object
name so the `vmi` externalRef and the whole status block are shared. Images are imported
from the registry with CDI rather than fetched over HTTP.

`os` and `image` are independent dropdowns. KDP's form cannot filter one field by another
field's value, so the pairing is documented in the field descriptions instead of enforced.

Retiring the old kind needed five steps, in order, because kro does not remove a CRD when
its RGD goes away and the agent does not prune what it published:

1. delete the consumer objects,
2. delete the old `PublishedResource`,
3. delete the RGD,
4. delete the CRD explicitly,
5. remove the stale entry from `APIExport.spec.resources` and delete the orphaned
   `APIResourceSchema`s.

Even after all five, `APIBinding.status.boundResources` still lists the old resource, and
the dashboard's create dialog still offers it. Pruning that needs the APIBinding recreated,
which deletes the workspace's objects, so it was left in place.

### Agent RBAC now grants the whole API group

The agent's ClusterRole enumerated each kind. The rename broke it, and the only symptom was
a `cannot list linuxvirtualmachines ... at the cluster scope` line in the agent log while
the kind silently never appeared in KDP. Since this service owns `kubev.k8c.io` outright,
the rule is now `resources: ["*"]` on that one group.

### SSH service and the guest agent

`LinuxVirtualMachine` now creates a port-22 `LoadBalancer` Service, mirroring the Windows
kind's RDP Service, plus cloud-init that installs `qemu-guest-agent` and provisions a
key-only `kkp` user from `spec.sshPublicKey`.

This surfaced a latent bug that predates the change: the Linux VM was getting the cluster
DNS service IP, which is not routable from inside a per-tenant kube-OVN VPC. It did not
matter while CDI fetched the image (CDI runs in an ordinary pod), but any in-guest network
work fails. Both branches now pin `dnsPolicy: None` with `8.8.8.8`, as the Windows kind
already did.

The Service's external IP stays pending: KubeLB's last hop is `nodeIP:nodePort`, which does
not reach a VM inside a custom VPC. The Service and its endpoint are correct in-cluster.

### Dropdowns: `x-kdp-field-source` is wired but does not resolve

The dashboard's create form is react-jsonschema-form fed from the CRD's OpenAPI v3 schema,
so a schema `enum` is already a dropdown. For runtime-known lists KDP parses a `kdp:options`
block out of a field's `description` (`options.kdp.k8c.io/v1` `FieldSource`) and is supposed
to populate the field from a live API call.

Wired onto `vpc` and `subnet`, the front half works: the field renders as a dropdown and the
request goes to the right URL and returns 200. The back half does not - the list holds a
single option that is the literal `value` expression. A control run with
`value: .metadata.uid` produced an option labelled `.metadata.uid`, confirming the expression
is passed through rather than evaluated. The blocks were reverted: a dropdown holding one
bogus entry is worse than a free-text field, because it stops the user typing a name that
would have worked.

Two traps worth recording:

- The RGD must use `|-`, not `|`. kro's marker parser reads the trailing newline a `|` block
  leaves behind as the start of a new marker and rejects the RGD with
  `marker key '' without a value`.
- `path` interpolates only `${LOCAL_WORKSPACE}`, `${APIEXPORT_WORKSPACE}` and
  `${LOCAL_NAMESPACE}`, never another form field.

KDP's UI builder (`Service.spec.generateUI`, `ui-config-*` ConfigMaps per view) is the other
route, and the practical one for fixing the VPC/Subnet pickers today. It was not used for
the enums because a schema `enum` is versioned with the service and also constrains
`kubectl` users, which a UI-only config does not.

### A custom VPC has no route out, and that is what broke the guest agent

The guest agent never appeared on the Linux VM. Two causes, found in order.

First, DNS. The VM inherited the cluster resolver `10.96.0.10`, which is a ClusterIP and is
not routable from a per-tenant kube-OVN VPC. Both Linux branches now pin `dnsPolicy: None`
with `8.8.8.8`.

That was necessary but not sufficient: the VM still could not reach the internet at all, so
`apt install qemu-guest-agent` produced nothing. A custom VPC in kube-OVN has no outbound
path, and the two fields that look like they provide one do not:

- `Subnet.spec.natOutgoing` SNATs from the node only for the **default** VPC. In a custom VPC
  it is silently a no-op.
- `Vpc.spec.enableExternal` and `extraExternalSubnets` require external gateway nodes, which
  means an `ovn-external-gw-config` ConfigMap and at least one labelled node. This cluster
  has neither, so kube-ovn-controller logged `no external gw nodes` on every reconcile and
  `status.enableExternal` stayed `false`. Both fields were removed from the Vpc RGD.

VPC peering was considered and rejected: it joins two VPC routers so their subnets can talk
to each other. It does no SNAT and creates no path to the outside, so it does not help here.

The mechanism that does work is `VpcEgressGateway` - a Deployment with one interface in the
tenant subnet and one in a provider-backed subnet of the default VPC, MASQUERADEing outbound.
The Subnet RGD now creates one per subnet, gated on `spec.egressGateway` (default `true`), so
each tenant gets its own and it is garbage-collected with the subnet.

It needs one cluster-wide prerequisite, `service-cluster/vpc-egress-external.yaml`: a
NetworkAttachmentDefinition plus a `172.30.0.0/24` Subnet in the default VPC carrying a
matching `provider`. The gateway attaches through multus, so an ordinary subnet cannot be
used - pointing it at `ovn-default` is rejected with `please set correct provider of subnet
... to get the network-attachment-definition`.

**So the gateway is per VPC (here per subnet) and the external network it attaches to is
central and one-time.**

One diagnostic that wasted time and is worth recording: testing egress from inside the
virt-launcher pod's network namespace proves nothing. With bridge binding KubeVirt hands the
pod's IP to the guest, so the pod netns has an empty route table by design. The valid test is
a plain pod annotated into the tenant subnet, which pinged `8.8.8.8` and resolved DNS once the
gateway was up.

Verified afterwards: `AgentConnected=True`, `status.guestOSInfo` reports
`Ubuntu 24.04.4 LTS` / kernel `6.8.0-124-generic`, and `status.interfaces[0].infoSource` is
`domain, guest-agent`.


### Field labels: acronym casing needs an OpenAPI `title`, painted on after kro

The create form showed "Os", "Ssh Public Key" and "Vpc", and the detail view additionally
mangled `loadBalancerIP` into "Load Balancer I P" and `v4availableIPrange` into
"V4available I Prange". Three routes were considered.

**1. A `title` in the schema - the right mechanism, but kro cannot emit one.** The dashboard
only derives a label when the property has no title (`requests.ts`:
`if (!property.title) property.title = toTitleCase(key)`; the detail view:
`schema?.title || toTitleCase(key)`), so a title fixes create form and detail view together.
kro's simple-schema marker allowlist (`pkg/simpleschema/markers.go`, `markerTypeFromString`)
has no `title=` in v0.9.3 or on `main`, and an unknown marker fails the whole RGD.

**2. The KDP UI builder / `ui-config-*` ConfigMaps - works, but far heavier.** These carry a
complete form definition (sections, rows, widgets, hardcoded dropdown options), one per kind
*and* per view, none of which is derived from the schema. Using it for casing would mean
hand-maintaining four full form specs that silently drift from the RGDs, and the existing
AI-generated Windows one had already invented VPC names that do not exist.

**3. Renaming the properties - rejected**, a breaking API change for a cosmetic problem.

So route 1 was taken, with the title applied to the CRD kro generates rather than to the RGD:
four RFC 6902 JSON Patch files (`*/crd-titles*.yaml`) applied by `just sc-titles`, which
`sc-rgds` now chains.

This holds because of two properties of kro's CRD reconciler. `pkg/graph/crd/compat` compares
description, defaults, enums, required and constraints, but **never `Title`** - so in steady
state kro reports "no changes" and does not write the CRD at all. When an RGD does change, kro
sends a JSON *merge* patch of the desired CRD, and since `spec.versions` is a list the merge
replaces it wholesale and the titles go. Hence the chaining. This was observed directly: after
editing only the Linux and Windows `vpc` descriptions, re-running the recipe reported `patched`
for those two CRDs and `patched (no change)` for the untouched Vpc and Subnet.

Verified in `/openapi/v3/apis/kubev.k8c.io/v1alpha1` - the document the dashboard fetches -
and in the browser: OS, SSH Public Key, VPC, Subnet, Load Balancer Class on the Linux form;
VPC on Windows; CIDR, NAT Outgoing, VPC on Subnet; Enable BFD, Static Routes, VPC Peerings on
Vpc. Existing VMs kept running across the schema republish.

One useful side effect: a stale `ui-config-*` ConfigMap cannot shadow the fix. The dashboard
stores a schema hash on the ConfigMap and falls back to the schema-driven form when it stops
matching, so adding titles invalidates any generated form by construction. That is why the
Windows create form reverted from the UI-builder layout to the default one.

### VM -> Subnet -> Vpc is gated with kro externalRefs, not Related Resources

The obvious candidate was the api-syncagent's Related Resources feature, and it is the
wrong tool. `spec.related` copies *satellite* objects (a Secret, a ConfigMap, another
published kind) alongside a primary object across the workspace boundary - the canonical
case being a cert-manager Certificate whose key material has to travel back to the user.
It carries no notion of ordering or existence; the docs say a reference to a non-existent
field is treated as "not yet existing" and deliberately not an error, and the agent does
not even watch related resources. Nothing in it would catch a mistyped `spec.subnet`.

The enforcement happens in kro instead. Both VM RGDs now open with two read-only handles
on the kube-OVN objects the Subnet and Vpc kinds already created:

```yaml
- id: tenantVpc
  externalRef:
    apiVersion: kubeovn.io/v1
    kind: Vpc
    metadata:
      name: kdp-${schema.metadata.labels['syncagent.kcp.io/remote-object-cluster']}-${schema.spec.vpc}

- id: tenantSubnet
  externalRef:
    apiVersion: kubeovn.io/v1
    kind: Subnet
    metadata:
      name: kdp-${schema.metadata.labels['syncagent.kcp.io/remote-object-cluster']}-${schema.spec.subnet}
  readyWhen:
    - ${tenantSubnet.status.v4availableIPrange != ""}
```

The VM's `logical_router` / `logical_switch` annotations then reference
`${tenantVpc.metadata.name}` and `${tenantSubnet.metadata.name}` rather than rebuilding the
name inline. That reference is the entire mechanism: **kro derives its DAG purely from CEL
references and has no explicit `dependsOn`** (the v0.9.3 resource schema has exactly
`externalRef`, `forEach`, `id`, `includeWhen`, `readyWhen`, `template`).

Points worth remembering:

- `Vpc` and `Subnet` are cluster-scoped, so the externalRef must not set
  `metadata.namespace`. kro refuses to build the RGD if it does.
- `readyWhen` may only reference its own node, so it cannot cross-check that the subnet
  actually belongs to the named VPC. `includeWhen` could, but `includeWhen: false` silently
  *skips* the VM and reports the instance ACTIVE, which is worse than blocking.
- Because both names are built from the object's own workspace label, a tenant structurally
  cannot attach to another tenant's network by guessing its name.
- This touches only `spec.resources`, never `spec.schema`, so the generated CRD is
  unchanged: no APIResourceSchema churn, no agent restart, no APIBinding work. It also
  meant the `sc-titles` patches reported "no change" and survived, which is a useful
  confirmation of why they stick.

**The Service needed gating too.** The first run blocked the VirtualMachine correctly but
still created the LoadBalancer Service, because `svc` referenced nothing from the subnet -
so a typo still burned a public IP for a VM that would never exist. The Service now carries
`kubev.k8c.io/subnet: ${tenantSubnet.metadata.name}`, which records the network it fronts
and creates the missing edge.

Verified both ways. With `subnet: does-not-exist-typo` the instance parks at `IN_PROGRESS`
with `waiting for external reference "tenantSubnet": not found`, and no VirtualMachine, no
Service and no public IP are created. Patching the field to the real subnet unblocked it and
both objects appeared, the Service carrying
`kubev.k8c.io/subnet=kdp-10p3s8dupeeavcyy-ubuntu-vm-subnet`. The three pre-existing VMs
reconciled through both RGD updates untouched.

A stuck `IN_PROGRESS` is still less obvious to a user than a rejected create. The only way to
reject at admission time is a kcp cross-workspace validating webhook hosted in the APIExport's
workspace, which means running and TLS-certing a webhook server. Not done, and probably not
worth it for this.

