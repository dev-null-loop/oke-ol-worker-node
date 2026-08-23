# oke-ubuntu-worker-node

Build an OCI custom image for OKE Ubuntu worker nodes with Packer.

## Build

Create a local var file first:

```bash
cd packer
cp dev.pkrvars.hcl.example dev.pkrvars.hcl
```

Set at least:
- `availability_domain`
- `compartment_ocid`
- `subnet_ocid`
- `base_image_ocid`
- `oke_repo_par`
- `k8s_version`

For the fast-start path, also set:
- `oke_default_prepull_images`

Run:

```bash
packer init .
packer build -var-file=dev.pkrvars.hcl .
```

## Defaults

- Ubuntu Noble (`24.04`)
- shape defaults to `VM.Standard.E5.Flex` with `1` OCPU and `12` GB RAM
- image metadata tags for `k8s_version`, base image, package, and profile
- helper packages baked in: `jq`, `curl`, `crictl`
- default OKE hot-path image pre-pull enabled
- CRI runtime enabled for earlier boot-time startup
- CNI host paths pre-created in the image
- bootstrap timing monitor enabled
- apt source URL is derived from `ubuntu_release`, `k8s_version`, and `oke_repo_par`
- OKE package name is derived as `oci-oke-node-all-<k8s_version>`
- image name is `ubuntu-<ubuntu_release>-YYYY.MM.DD-OKE-<k8s_version>-<optimization_profile>`

## Fast Start

- Define the built-in OKE pre-pull set through `oke_default_prepull_images`.
- Treat `oke_default_prepull_images` as version-specific data in the `.pkrvars` file, not as a stable forever-list.
- Refresh that list from a fresh-node pull observation whenever `k8s_version` changes or OKE changes the first-node image set.
- Typical entries are:
  - `oke-public-vcn-native-ip-cni-plugin`
  - `oke-public-cloud-provider-oci`
  - `oke-public-proxymux-cli`
  - digest-pinned refs such as `kube-proxy` or `pause` when needed
- Recommended additional pre-pull for the current KPO startup-taint workaround:
  - `public.ecr.aws/z2c7x8q5/bitnami/kubectl@sha256:78726c39c86a468752790cd392839cef1282095400bb3cdf3619ab5dae9c8d2c`
- Add any extra first-pod-path images through `additional_prepull_images`.
- Timing lands in `/var/log/oke-optimized-bootstrap-timing.log`.
- The repo can optimize image contents and image-time pulls. It cannot by itself remove Karpenter-side orchestration delays such as external startup-taint helpers.
- The tracked example file is `packer/dev.pkrvars.hcl.example`. Keep your real `dev.pkrvars.hcl` local.

## Files

- `packer/image.pkr.hcl`: OCI Packer build
- `packer/variables.pkr.hcl`: input variables
- `packer/dev.pkrvars.hcl.example`: canonical fast-start example values
- `scripts/install-oke-node-packages.sh`: installs OKE Ubuntu packages into the image
- `scripts/lib/common.sh`: apt locking, guest cleanup, and wait-online handling
- `scripts/lib/prepull.sh`: CRI startup, image pre-pull, and OCI CNI asset seeding
- `scripts/lib/timing-monitor.sh`: bootstrap timing monitor installation
- `cloud-init/managed-minimal.yaml`: managed node bootstrap
- `cloud-init/self-managed-minimal.yaml`: self-managed node bootstrap
- `docs/how-this-actually-works.md`: fast orientation for a fresh session
- `docs/startup-optimization-plan.md`: current fast-start status and repo boundaries
