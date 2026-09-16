# UI Builder: a saved UI configuration stays permanently "outdated" because Save re-writes the stale schema hash

> **Filed as [kubermatic/developer-platform-dashboard#1167][issue]** on 2026-09-16.
>
> [issue]: https://github.com/kubermatic/developer-platform-dashboard/issues/1167
>
> This file stays the local source of truth for the report. If you update the issue, update this
> file too, and vice versa.
>
> Labels still need to be applied by someone with triage rights on that repo: `kind/bug`, `sig/ui`.
> They could not be set at filing time - the GitHub API rejected `AddLabelsToLabelable` for
> `toschneck`, which can open issues there but not label them.

## Summary

`saveViewConfig` in the UI Builder resolves the schema-hash annotation by preferring the value
already stored on the ConfigMap and only falling back to the freshly computed hash when no
ConfigMap exists yet. Because a ConfigMap always carries that annotation after its first
generation, every subsequent Save writes the **old** hash back unchanged.

The dashboard decides whether a UI configuration is "outdated" by comparing the current schema hash
against that stored annotation, so the amber "Outdated UI Configuration" banner can never be cleared
from inside the product, and the dashboard refuses to render the stored configuration at all.
Once the schema behind a published resource changes, that resource's custom UI is dead until
somebody deletes the ConfigMap out-of-band with `kubectl`.

Both save paths are affected: the `Regenerate` button flow, and the ordinary chat-generate -> `Save`
flow.

## Environment

| Item                  | Value                                                                       |
| --------------------- | --------------------------------------------------------------------------- |
| Repository            | `kubermatic/developer-platform-dashboard`                                   |
| Offending file        | `packages/web/src/lib/apis/service-objects/ui-config-hooks.ts`              |
| Detection logic       | `packages/web/src/lib/apis/service-objects/ui-config.ts`                    |
| Dashboard             | https://platform-demo.lab.kubermatic.io                                     |
| Organization          | `tobi-org`                                                                  |
| Service               | `kubev.k8c.io`                                                              |
| Affected kind         | `WindowsVirtualMachine` (`kubev.k8c.io/v1alpha1`)                           |
| Product area          | KDP dashboard, UI Builder (Service -> UI Builder tab)                       |
| Reproduced            | 2026-09-03 (black box, on the environment above)                            |
| Re-verified           | 2026-09-16 (source read of `main`; defect still present)                    |
| Reporter              | Tobias Schneck <tobias.schneck@kubermatic.com>                              |

At the time of writing, `ui-config-hooks.ts` was last modified on 2026-05-29 by
`8bf3f5b` ("Fetch provider UI configs via virtual workspace", #910), no open PR touches it, and no
existing issue describes this behaviour.

## Impact

- Any published resource whose schema evolves, which is every service under active development,
  permanently loses its custom UI on the first schema change.
- There is no in-product recovery: the only exit is `kubectl` access to the KDP workspace.
- Users who do not have cluster-level `kubectl` access to the KDP workspace cannot recover at all.
- The failure is silent from the author's point of view: `Regenerate` and `Save` both report
  success, and the loss only becomes visible after a page reload.

## Root cause

`saveViewConfig`, `packages/web/src/lib/apis/service-objects/ui-config-hooks.ts` (lines 126-136 at
the time of writing):

```ts
const schemaHash =
  generatedConfigMap?.annotations?.[UI_GENERATOR_SCHEMA_HASH_ANNOTATION] ??
  userConfigMap?.annotations?.[UI_GENERATOR_SCHEMA_HASH_ANNOTATION] ??
  (await computeSchemaHash(
    serviceResource.schema as unknown as Record<string, unknown>
  ));

const annotations: Record<string, string> = {
  [UI_GENERATOR_VERSION_ANNOTATION]: UI_GENERATOR_VERSION,
  [UI_GENERATOR_SCHEMA_HASH_ANNOTATION]: schemaHash,
};
```

`computeSchemaHash(serviceResource.schema)` - the only expression that reflects the **current**
schema - sits last in the `??` chain, so it is reached only when neither ConfigMap carries the
annotation. After the first generation one of them always does, so the stale value wins and is
written straight back. The annotation therefore becomes a permanent record of the schema as it was
when the ConfigMap was first created.

The detection side, `packages/web/src/lib/apis/service-objects/ui-config.ts`:

```ts
const isSchemaOutdated =
  !!currentSchemaHash && !!storedHash && currentSchemaHash !== storedHash;
```

compares the freshly computed hash against that pinned value, so once the schema moves the
comparison is true forever.

This explains every observed symptom, including why deleting the ConfigMap fixes it: with no
existing object, `exists` is `false`, both `??` operands are `undefined`, and the fallback finally
computes the correct hash.

For contrast, the backend UI-generator controller in `kubermatic/developer-platform`
(`cmd/kdp-controller-manager/pkg/controllers/ui-generator/controller.go`) does it correctly - it
stamps `cm.Annotations[configMapAnnotationSchemaHash] = schemaHash` from the schema it just
generated against. Only the dashboard's interactive save path is affected.

## Steps to reproduce

1. Change the `APIResourceSchema` behind a published resource so that its schema hash changes.
   In our case a kro `ResourceGraphDefinition` was updated, which republished the
   `WindowsVirtualMachine` schema through the api-syncagent / `APIExport`.
2. Open the UI Builder and select the affected resource. The amber "Outdated UI Configuration"
   banner appears and Preview shows "No form generated yet". Expected so far.
3. Click `Regenerate`. A 6-prompt pipeline runs ("Regenerating (2/6 prompts)...") and produces a
   correct, complete UI in the Preview pane. The banner turns green:

   > UI Regenerated - The UI has been regenerated with the latest version. Remember to save your
   > changes.

4. Click `Save`. The ConfigMap is written: `metadata.resourceVersion` advances and `data` holds the
   new UI. But `internal.kdp.k8c.io/ui-generator-schema-hash` is byte-for-byte unchanged.
5. Reload the page and reselect the resource. The amber "Outdated UI Configuration" banner is back
   and Preview is again "No form generated yet". Go to step 3, forever.

## Expected vs actual

| Step                             | Expected                                                      | Actual                                                            |
| -------------------------------- | ------------------------------------------------------------- | ----------------------------------------------------------------- |
| After `Regenerate`               | Regenerated UI in the Preview pane, green confirmation banner | As expected                                                       |
| After `Save`                     | `data` **and** the schema-hash annotation are written         | Only `data` is written, annotation keeps its old value            |
| After page reload                | Saved custom UI renders, no banner                            | Amber "Outdated UI Configuration" banner, "No form generated yet" |
| Recovery from inside the product | Regenerate + Save clears the outdated state                   | Impossible without an out-of-band `kubectl` delete                |

## Evidence

All ConfigMaps live in namespace `default` of the KDP workspace and are prefixed
`ui-config-kubev.k8c.io-v1alpha1-`; only the suffix is shown.

**Before `Regenerate` + `Save`:**

| ConfigMap (suffix)                  | `internal.kdp.k8c.io/ui-generator-schema-hash`                     | `metadata.resourceVersion` |
| ----------------------------------- | ------------------------------------------------------------------ | -------------------------- |
| `windowsvirtualmachine-create-form` | `009c8d36d649aa83a69465ad27ca86f46fa88dd00f3534584b5dbe785b2990eb` | `83204137`                 |
| `windowsvirtualmachine-detail-view` | `b0957dab88cf005d709e626789b3b7834620f029f0cdf7de54192e57eb3b80fd` | `83204290`                 |
| `windowsvirtualmachine-list-view`   | `b0957dab88cf005d709e626789b3b7834620f029f0cdf7de54192e57eb3b80fd` | `83204214`                 |

**After `Regenerate` + `Save` on the create form:**

| ConfigMap (suffix)                  | `internal.kdp.k8c.io/ui-generator-schema-hash`                     | `metadata.resourceVersion` |
| ----------------------------------- | ------------------------------------------------------------------ | -------------------------- |
| `windowsvirtualmachine-create-form` | `009c8d36d649aa83a69465ad27ca86f46fa88dd00f3534584b5dbe785b2990eb` | `83209172`                 |

`metadata.resourceVersion` advanced from `83204137` to `83209172`, so the write definitely happened
and the new UI landed in `data`. The hash annotation is identical to the value it had before the
save, which is the whole bug.

**Control:** a ConfigMap that was *created fresh* after the same schema change picks up the current
hash and shows no banner. Only updates fail to refresh it.

| ConfigMap (suffix)                                                        | `internal.kdp.k8c.io/ui-generator-schema-hash`                     | Banner? |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------ | ------- |
| `linuxvirtualmachine-create-form` (created fresh after the schema change) | `8b9f7aeccecc94927626b90cb157258a1c522cbb1864007e64ffb7ad2f2d2036` | no      |
| `windowsvirtualmachine-create-form` (pre-existing, updated by Save)       | `009c8d36d649aa83a69465ad27ca86f46fa88dd00f3534584b5dbe785b2990eb` | yes     |

**The hash is a plain per-kind schema hash.** Before the workaround, `list-view` and `detail-view`
shared one value while `create-form` had another, which briefly looked like a per-(kind, view)
grouping. Recreating all three produced one identical value across all of them,
`cc10d9b49b5a05113fdb389dba7de7bd90f812fe57fff2ca46997c7209593576`. The earlier split was simply
two generation times against two schema versions, each frozen by this bug - so it is extra evidence
for the root cause above, not a separate quirk.

## Workaround (verified)

Delete the ConfigMap(s) out-of-band, then regenerate and save. A newly created ConfigMap takes the
`computeSchemaHash` fallback and gets the current hash.

```sh
kubectl delete configmap -n default \
  ui-config-kubev.k8c.io-v1alpha1-windowsvirtualmachine-create-form \
  ui-config-kubev.k8c.io-v1alpha1-windowsvirtualmachine-list-view \
  ui-config-kubev.k8c.io-v1alpha1-windowsvirtualmachine-detail-view
```

Confirmed end to end on 2026-09-03 for `WindowsVirtualMachine`: after deleting the three
ConfigMaps, the "Outdated UI Configuration" banner disappeared immediately and the Chat pane became
usable again. Regenerating the create form, list view and detail view and saving each produced three
new ConfigMaps all stamped with the current schema hash, and a full page reload rendered the saved
custom UI with no banner.

This requires `kubectl` access to the KDP workspace, so it is not available to every affected user.

## Suggested fix

Invert the precedence so that the current schema decides the hash, and fall back to a stored value
only when the schema is unavailable:

```ts
const schemaHash = serviceResource.schema
  ? await computeSchemaHash(
      serviceResource.schema as unknown as Record<string, unknown>
    )
  : (generatedConfigMap?.annotations?.[UI_GENERATOR_SCHEMA_HASH_ANNOTATION] ??
     userConfigMap?.annotations?.[UI_GENERATOR_SCHEMA_HASH_ANNOTATION]);
```

The UI being saved was generated against `serviceResource.schema`, so hashing that schema records
what the stored UI actually corresponds to - which is exactly what the outdated check wants to know.

Secondary hardening, worth considering separately:

- Make the "outdated" gate non-destructive: render the stored UI with a warning instead of refusing
  to show it, so a stale or missing annotation degrades gracefully rather than bricking the view.
- Add a regression test asserting that saving over an existing ConfigMap whose stored hash differs
  from the current schema hash results in the **current** hash being persisted.
  `packages/web/src/lib/apis/service-objects/ui-config.test.ts` already covers the hash helpers.

## Related issues

Prior work in the same area, all closed, none covering this defect:

| Issue  | Title                                                                  |
| ------ | ---------------------------------------------------------------------- |
| #803   | Split up generated views into different ConfigMaps and save additional metadata |
| #804   | Regeneraton Logic                                                      |
| #745   | Come up with a plan how to maintain the ui generator mechanism and library long term |
