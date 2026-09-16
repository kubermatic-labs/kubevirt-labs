# Operations

Every action on this service goes through the Justfile. `just` on its own lists the recipes,
grouped as `lifecycle`, `kdp`, `service cluster`, `demo` and `inspect`.

## Prerequisites on the service cluster

KubeVirt, CDI, kube-OVN, a `kubev-vms` StorageClass, and for Windows a golden image PVC
named by `spec.templateImageName` in `kubermatic-virtualization`. `just preflight` checks all
of them. kro is installed by `just sc-kro`.

The egress gateways additionally need `service-cluster/vpc-egress-external.yaml` applied
once, cluster-wide - see [networking.md](networking.md).

## Target naming

Targets are prefixed by the side they touch:

| prefix  | side                                                    |
|---------|---------------------------------------------------------|
| `kdp-`  | the KDP/kcp workspace that offers the service           |
| `sc-`   | the service cluster that runs the VMs                   |
| `demo-` | consumer objects, applied the way a platform user would |
| `show-` | read-only inspection                                    |
| (none)  | whole lifecycle: `preflight`, `deploy`, `clean`         |

## Everyday commands

```bash
just                            # list recipes, grouped by side
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

## The deploy chain

`deploy` chains, in order:

```
sc-kro  kdp-service  sc-agent-secret  sc-agent  sc-rgds  sc-publish  kdp-schemas  kdp-ui
```

Ordered so that missing prerequisites surface early. Two links are worth knowing on their
own:

- `sc-rgds` chains `sc-titles`, because a plain `kubectl apply` of an RGD wipes the OpenAPI
  titles the dashboard needs ([kdp-ui.md](kdp-ui.md)).
- `kdp-schemas` repoints the APIExport at the schemas the agent actually published. It is a
  no-op when already current, and it is the step that stops KDP serving a stale API shape
  ([troubleshooting.md](troubleshooting.md)).

`sc-agent-restart` picks up a changed PublishedResource without a full redeploy.

## After an RGD schema change

```bash
just sc-rgds            # applies the RGDs, then re-stamps the CRD titles
just sc-agent-restart   # agent publishes a fresh APIResourceSchema
just kdp-schemas        # APIExport now points at it
```

Then regenerate the affected UI configs, because a schema change invalidates their stored
hash and the dashboard silently falls back to the default view. See
[kdp-ui.md](kdp-ui.md).

**Removing a field is a different operation.** kro refuses the CRD update, reports success
anyway, and the only way forward destroys every object of that kind. Read
[troubleshooting.md](troubleshooting.md) first.

## Publishing the service

Making the service visible and bindable to other organizations is covered separately in
[publishing.md](publishing.md).
