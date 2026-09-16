# Changelog

Notable changes to the KubeVirt-VMs-as-a-Service KDP offering. Dates are the commit dates on
`main`.

## Unreleased

### Changed

- `Vpc`, `Subnet` and both VM kinds now go through KubeVirtualization's
  `virtualization.k8c.io` wrapper kinds instead of creating `kubeovn.io` objects directly.
  The wrapper provisions the NetworkAttachmentDefinition and makes the tenant networks
  visible in the KubeV dashboard.
- VMs attach through multus (`networkName: <ns>/<tenantSubnet.status.realName>`) rather than
  kube-OVN pod annotations.
- `Vpc.spec.vpcPeerings[].remoteVpc` renamed to `remoteVpcRef`.
- `deploy` now also runs `kdp-schemas` and `kdp-ui`.

### Added

- `just kdp-schemas` repoints the APIExport at the APIResourceSchemas the agent actually
  published. Without it KDP keeps serving the previous API shape with no error anywhere.
- `just sc-rgds-recreate` rebuilds a CRD stuck on a breaking schema change, and refuses while
  any objects of that kind still exist.
- `just kdp-ui` / `just kdp-ui-export` apply and re-export the dashboard create forms and
  list views, now checked in under `kdp/ui-config/`.
- `sc-rgds` waits on the RGD's `Ready` condition instead of `status.state`, which stays
  `Active` even when kro has refused the CRD update.
- Status surfaced on the network kinds: `realName`, `vpcRealName`, `phase`, `availableIPs`,
  with OpenAPI titles so the dashboard labels them properly.
- Documentation split out of the README into `docs/`: API reference, networking, KDP UI,
  operations, publishing, troubleshooting. Architecture graphic from the ContainerDays
  Hamburg 2026 talk added to the README.

### Removed

- `Subnet.spec.externalSubnet`, which had been unused since outbound moved to the per-subnet
  `VpcEgressGateway`. Removing it is what required `sc-rgds-recreate`.

## 2026-09-03

Reworked from a hand-run example into a deployable service.

### Added

- `Justfile` covering the whole lifecycle, grouped by the side each target touches.
- KDP `Service` (`kdp/service.yaml`) reserving the `kubev.k8c.io` API group, plus catalog
  logo and `kdp/public-rbac.yaml` for cross-org `get` + `bind`.
- `LinuxVirtualMachine` replacing the Ubuntu-only kind: `spec.os` selects Ubuntu or Flatcar,
  with a separate cloud-init mechanism per guest and an SSH LoadBalancer Service.
- Per-subnet `VpcEgressGateway`, plus the cluster-wide
  `service-cluster/vpc-egress-external.yaml` it attaches to. A custom kube-OVN VPC has no
  outbound path without it.
- `*/crd-titles*.yaml` JSON patches stamping OpenAPI titles onto the kro-generated CRDs, so
  the dashboard renders `OS`, `VPC` and `SSH Public Key`.
- RBAC the upstream charts omit: the agent's leaderelection Role and kro's access to the API
  groups these RGDs touch.
- `just preflight` checking every prerequisite on both clusters before anything is changed.

### Changed

- `ubuntu/` renamed to `linux/`.

## 2026-03-24

Initial example: `Vpc`, `Subnet`, Ubuntu and Windows VM `ResourceGraphDefinition`s with their
PublishedResources, kcp sync-agent helm values and RBAC, and the architecture diagram.
