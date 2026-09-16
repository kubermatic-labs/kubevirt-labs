# The KDP dashboard

Everything the platform user sees in the KDP dashboard is derived from the CRD's OpenAPI v3
schema. kro cannot emit all of it, and the dashboard ignores some of the usual Kubernetes
levers entirely, so three separate mechanisms are in play: schema `enum`s, `kdp:options`
blocks inside field descriptions, and JSON patches that stamp `title` onto the generated
CRDs.

## Dropdowns

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

## The UI builder

An alternative for UI-only tweaks is KDP's built-in
[UI builder](https://platform-demo.lab.kubermatic.io/organizations/tobi-org/services/kubev.k8c.io/ui-builder),
which stores a per-view `ui-config-*` ConfigMap (`create-form`, `detail-view`, `list-view`)
in KDP; `Service.spec.generateUI: true` makes KDP generate one automatically. It is the
better tool for layout and labels, and the pragmatic place to fix the VPC/Subnet pickers
while `kdp:options` is broken. The schema-side approach is used here because it lives in the
RGD, so it is versioned with the service and applies to every consumer of the API, not just
the dashboard.

`kdp/ui-config/` holds the create forms and list views that are checked in, applied by
`just kdp-ui` and re-exported with `just kdp-ui-export` after editing them in the UI builder.

Each UI config stores a hash of the schema it was generated against. When an RGD schema
changes the hash stops matching and **the dashboard silently falls back to the default
view** - no error anywhere. Re-generate and re-export after schema edits.

**That fallback is a one-way door.** Once a view is marked outdated, neither `Regenerate`
nor `Save` can clear it: the dashboard writes back the hash already stored on the ConfigMap
instead of the freshly computed one, so the annotation stays frozen at whatever the schema
looked like when the ConfigMap was first created. The only recovery is to delete the
ConfigMap and regenerate from scratch. Filed upstream as
[kubermatic/developer-platform-dashboard#1167][ui-builder-issue]; the full write-up, evidence
and workaround are in
[`issues/kdp-ui-builder-outdated-config-deadlock.md`](issues/kdp-ui-builder-outdated-config-deadlock.md).

## List columns

The dashboard **ignores CRD `additionalPrinterColumns` entirely**. Columns come from the
`list-view` UI config instead, and its picker only offers status *conditions* and *spec*
properties - so arbitrary status fields such as `status.availableIPs` cannot be made into
columns.

## Field labels and acronym casing

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
|-----------------------------------------|---------------------------------------|
| `linux/crd-titles.yaml`                 | `linuxvirtualmachines.kubev.k8c.io`   |
| `windows/crd-titles.yaml`               | `windowsvirtualmachines.kubev.k8c.io` |
| `vpc-networking/crd-titles-vpc.yaml`    | `vpcs.kubev.k8c.io`                   |
| `vpc-networking/crd-titles-subnet.yaml` | `subnets.kubev.k8c.io`                |

`just sc-titles` applies all four, and `sc-rgds` chains it automatically - because a plain
`kubectl apply` of an RGD wipes the titles.

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

A stale `ui-config-*` ConfigMap from the UI builder does not shadow this - adding titles
marks any generated form outdated by construction, and the dashboard then falls back to the
schema-driven form. See *The UI builder* above for why that state cannot be cleared from
inside the product.

[ui-builder-issue]: https://github.com/kubermatic/developer-platform-dashboard/issues/1167
[react-jsonschema-form]: https://rjsf-team.github.io/react-jsonschema-form/
