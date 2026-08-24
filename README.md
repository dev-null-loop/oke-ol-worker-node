# oke-ol-worker-node

Build an OCI custom image for OKE Oracle Linux 8 worker nodes with Packer.

The image is referenced at runtime from `private-oke-karpenter` through `OCINodeClass.imageId`.

## Inputs

Set local values in `packer/dev.pkrvars.hcl`:

Required:

- `availability_domain`
- `compartment_ocid`
- `subnet_ocid`
- `base_image_ocid`
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

1. start from an official OKE Oracle Linux 8 worker image
2. install `jq`, `curl`, and `crictl`
3. pre-create OCI CNI host directories
4. mask wait-online services
5. enable the CRI service at boot
6. pre-pull the configured image set
7. pre-seed OCI CNI host assets when the OCI CNI image is included
8. install the bootstrap timing monitor
9. sanitize guest state before image capture

## Implemented Optimizations

1. use the official OKE Oracle Linux 8 worker image as the base
2. bake in bootstrap helper tools: `jq`, `curl`, `crictl`
3. pre-create OCI CNI host paths:
   - `/opt/cni/bin`
   - `/etc/cni/net.d`
   - `/etc/oci-cni`
4. mask `wait-online` services to avoid unnecessary boot blocking
5. enable the CRI runtime and `oke.service` for earlier boot-time startup
6. pre-pull the standard first-boot OKE image set into the image
7. pre-seed OCI CNI host assets from the OCI CNI image:
   - CNI binaries
   - OCI CNI config
   - supporting iptables assets
8. install a bootstrap timing monitor that writes `/var/log/oke-optimized-bootstrap-timing.log`
9. sanitize guest state before image capture

## Defaults and Built Image Contents

- Oracle Linux 8 OKE image
- shape defaults to `VM.Standard.E5.Flex` with `1` OCPU and `12` GB RAM
- image metadata tags for `k8s_version`, base image, and profile
- helper packages baked in: `jq`, `curl`, `crictl`
- CRI runtime enabled for earlier boot-time startup
- CNI host paths pre-created in the image
- bootstrap timing monitor enabled
- image name is `ol8-YYYY.MM.DD-OKE-<k8s_version>-<optimization_profile>`
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
  - validates the Oracle Linux 8 base image
  - refreshes package metadata
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
- image-time package installation for helper tooling
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
