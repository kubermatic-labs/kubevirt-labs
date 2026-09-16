# Publishing to other organizations

By default the service is visible only in the workspace that offers it. Two RBAC grants make
it available to the rest of the installation.

## How catalog visibility works

The service catalog wildcard-lists Services across every provider workspace and then decides
per object what the caller may see, using ordinary RBAC **in the provider workspace**. Three
grants, doing different jobs:

| grant                    | effect                                                            |
|--------------------------|-------------------------------------------------------------------|
| `get` on the Service     | the tile appears in another org's catalog, in full                |
| `catalog` on the Service | tile appears with name and labels only - no spec, browse-only     |
| `bind` on the APIExport  | the other org may actually create an APIBinding and use the kinds |

`kdp/public-rbac.yaml` grants `get` + `bind` to `system:authenticated`, i.e. every org on the
installation.

```bash
just kdp-publish      # apply the grants
just kdp-unpublish    # revoke them
```

## What is and is not isolated

Multi-tenancy on the **naming** side is already handled: every PublishedResource prefixes
objects with `kdp-{{ .ClusterName }}-`, so two orgs creating a VPC of the same name do not
collide. The rules are in [`../README.md`](../README.md#naming-and-multi-tenancy).

What is **not** isolated is the service cluster. Every org's VMs land in the single
`kubermatic-virtualization` namespace and share its quota and storage. Nothing stops one
tenant from exhausting it for everybody else.

Networking *is* isolated per tenant, because each `Vpc` is a separate kube-OVN router and
each `Subnet` gets its own egress gateway ([networking.md](networking.md)).
