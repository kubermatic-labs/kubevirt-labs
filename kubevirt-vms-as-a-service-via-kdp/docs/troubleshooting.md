# Troubleshooting

The failure modes worth knowing about before they cost you an afternoon, plus the list of
smaller gotchas this service is built around.

## Two silent-failure modes the Justfile now catches

Both of these used to report success while doing nothing, which is worse than an error.

### kro reports `Active` on a refused CRD update

A kro-generated CRD can only *gain* properties. Dropping one is refused with
`breaking changes detected: Property x was removed`, the RGD goes `Ready=False` - and
`status.state` stays `Active` regardless. Anything that gates on `state` therefore passes
while the CRD silently keeps the old schema. `sc-rgds` now waits on `conditions[Ready]`,
prints the offending property on failure, and exits non-zero.

There is no override in kro v0.9.3 (`RGD.spec` has only `resources` and `schema`, and the
controller takes no relevant flag), so a property removal means rebuilding the CRD - which
deletes every object of that kind. `just sc-rgds-recreate` does that, but **refuses while
any objects still exist**:

```
REFUSING: vpcs.kubev.k8c.io still has 2 object(s) on the service cluster.
Rebuilding its CRD would delete them. Remove the consumer objects first.
```

Prefer adding fields over removing them. A field that is merely unused can be left in
place with a comment, which is why `externalSubnet` survived as long as it did.

Deleting the RGD alone does not drop the CRD; the CRD has to go too, after confirming no
instances remain.

### The APIExport does not follow republished schemas

The api-syncagent creates a new APIResourceSchema when a published CRD changes, but never
rewrites `APIExport.spec.resources` - rebinding is the service owner's decision, since
consumers are bound to the old shape. Until it is repointed, KDP keeps serving the previous
shape and `kubectl explain` in the workspace shows stale fields, with no error anywhere.

`just kdp-schemas` repoints it, reading each PublishedResource's
`status.resourceSchemaName` - which is authoritative, so there is no guessing by
timestamp. It is chained into `deploy` and is a no-op when already current.

The post-schema-change runbook is in [operations.md](operations.md#after-an-rgd-schema-change).

## Silent failures elsewhere

A few more things in this stack fail without saying so. They are documented where they
belong, listed here so they are findable:

| Symptom                                                       | Cause                                               | Where                                |
|---------------------------------------------------------------|-----------------------------------------------------|--------------------------------------|
| Dashboard shows the default form instead of the custom one    | UI config's schema hash no longer matches           | [kdp-ui.md](kdp-ui.md)               |
| "Outdated UI Configuration" that Save/Regenerate cannot clear | dashboard writes back the stale hash                | [kdp-ui.md](kdp-ui.md)               |
| VPC/Subnet dropdown lists the literal `value` expression      | `kdp:options` value expression is never evaluated   | [kdp-ui.md](kdp-ui.md)               |
| Subnet stuck in `Provisioning`, nothing on the object         | subnet name over 13 chars, NAD label value too long | [networking.md](networking.md)       |
| Windows VM sits `Stopped`, no DataVolume phase, no Event      | CDI clone target smaller than the golden image PVC  | [api-reference.md](api-reference.md) |
| `apt` in cloud-init never runs, guest agent never appears     | guest DNS points at the unreachable cluster DNS IP  | [api-reference.md](api-reference.md) |
| VM parks at `IN_PROGRESS`, no VirtualMachine created          | `spec.vpc` / `spec.subnet` names a missing object   | [networking.md](networking.md)       |
| Public LoadBalancer IP never answers                          | KubeLB's last hop cannot reach a custom VPC         | [networking.md](networking.md)       |

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
- **Do not strip `status.conditions` in a PublishedResource mutation.** The dashboard reads
  `status.conditions[Ready]` to draw the Ready dot in the service catalog; deleting it makes
  the UI show "No condition data" for that kind while everything is in fact healthy.
- **The Windows golden image is cloned same-namespace, Block to Block.** A filesystem target
  fails the clone on `lost+found`.
