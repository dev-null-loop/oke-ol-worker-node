# oke-ubuntu-worker-node

Build an OCI custom image for OKE Ubuntu worker nodes with Packer.

The image is referenced at runtime from `private-oke-karpenter` through `OCINodeClass.imageId`.

## Inputs

Set local values in `packer/dev.pkrvars.hcl`:

Required:

- `availability_domain`
- `compartment_ocid`
- `subnet_ocid`
- `base_image_ocid`
- `oke_repo_par`
- `k8s_version`
- `oke_default_prepull_images`

Optional:

- `additional_prepull_images`
- `ssh_private_key_file`
- `ssh_public_key_file`

Defaults live in `packer/variables.pkr.hcl`.

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

## Build Flow

Entrypoint:

- `packer/image.pkr.hcl`

Provisioning steps:

1. wait for `cloud-init`
2. upload `scripts/lib` to the build instance
3. run `scripts/install-oke-node-packages.sh`

## Optimization Steps

1. configure the OKE apt source during the image build
2. install `oci-oke-node-all-<k8s_version>` during the image build
3. remove `unattended-upgrades`
4. install `jq`, `curl`, and `crictl`
5. pre-create OCI CNI host directories
6. mask wait-online services
7. enable the CRI service at boot
8. pre-pull the configured image set
9. pre-seed OCI CNI host assets when the OCI CNI image is included
10. install the bootstrap timing monitor
11. sanitize guest state before image capture

## Defaults and Built Image Contents

- Ubuntu Noble (`24.04`)
- shape defaults to `VM.Standard.E5.Flex` with `1` OCPU and `12` GB RAM
- image metadata tags for `k8s_version`, base image, package, and profile
- helper packages baked in: `jq`, `curl`, `crictl`
- CRI runtime enabled for earlier boot-time startup
- CNI host paths pre-created in the image
- bootstrap timing monitor enabled
- apt source URL is derived from `ubuntu_release`, `k8s_version`, and `oke_repo_par`
- OKE package name is derived as `oci-oke-node-all-<k8s_version>`
- image name is `ubuntu-<ubuntu_release>-YYYY.MM.DD-OKE-<k8s_version>-<optimization_profile>`
- `unattended-upgrades` removed
- wait-online services masked
- guest state sanitized before capture

## Pre-pull Images

- `oke_default_prepull_images` contains the standard image set for the selected OKE/Kubernetes version
- update that list when `k8s_version` changes or the first-boot pull set changes
- typical entries include `oke-public-vcn-native-ip-cni-plugin`, `oke-public-cloud-provider-oci`, `oke-public-proxymux-cli`, and digest-pinned refs such as `kube-proxy`
- `additional_prepull_images` is for extra images outside the standard set
- timing lands in `/var/log/oke-optimized-bootstrap-timing.log`
- keep the real `packer/dev.pkrvars.hcl` local; use `packer/dev.pkrvars.hcl.example` as the tracked example

## Script Roles

- `scripts/install-oke-node-packages.sh`
  - validates the Ubuntu base image
  - configures the OKE apt repository
  - installs the OKE node package
  - enables the runtime
  - invokes helper modules

- `scripts/lib/common.sh`
  - apt lock handling
  - wait-online masking
  - guest cleanup before image capture

- `scripts/lib/prepull.sh`
  - runtime startup for pre-pull
  - image pre-pull
  - OCI CNI host asset seeding

- `scripts/lib/timing-monitor.sh`
  - timing monitor installation

## Scope

This repo covers:

- image contents
- image-time package installation
- image-time pulls
- guest bootstrap measurement

This repo does not cover:

- OCI instance launch time
- Karpenter/KPO orchestration delay before launch
- OCI native pod networking convergence after node registration

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
