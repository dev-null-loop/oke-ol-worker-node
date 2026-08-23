# How This Works

This repo builds a custom Ubuntu OKE worker image for fast-start Karpenter/KPO testing.

## Inputs

Required local values live in `packer/dev.pkrvars.hcl`:

- `availability_domain`
- `compartment_ocid`
- `subnet_ocid`
- `base_image_ocid`
- `oke_repo_par`
- `k8s_version`
- `oke_default_prepull_images`

Optional local values:

- `additional_prepull_images`
- `ssh_private_key_file`
- `ssh_public_key_file`

Stable repo defaults live in `packer/variables.pkr.hcl`.

## Build Path

Packer entrypoint:

- `packer/image.pkr.hcl`

Provisioning flow:

1. wait for `cloud-init`
2. upload `scripts/lib` to the build instance
3. run `scripts/install-oke-node-packages.sh`

Main script responsibilities:

- `scripts/install-oke-node-packages.sh`
  - validates Ubuntu base image
  - configures the OKE apt repository
  - installs the OKE node package
  - enables early runtime startup
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
  - installs the bootstrap timing monitor service

## What The Built Image Does

The resulting image bakes in:

- Ubuntu OKE node package for the chosen `k8s_version`
- helper packages:
  - `jq`
  - `curl`
  - `crictl`
- early CRI startup
- configured image pre-pulls
- OCI CNI host assets when the OCI CNI image is present
- bootstrap timing monitor service

It also removes or reduces first-boot work by:

- disabling `unattended-upgrades`
- masking wait-online services
- pre-creating CNI host directories
- sanitizing guest state before image capture

## How KPO Uses The Image

This repo only builds the image.

The live KPO consumption happens in the separate repo:

- `private-oke-karpenter`

That repo should reference the image through an `OCINodeClass` boot-volume image ID, using:

- `imageType: OKEImage`
- explicit `imageId`

This repo does not manage the KPO runtime manifests.

## What Was Optimized

Repo-controlled optimizations:

- bake-time package installation
- bake-time image pre-pull
- early CRI enablement
- OCI CNI host asset pre-seeding
- bootstrap timing instrumentation
- wait-online masking
- guest cleanup before capture

## What Is Still Outside Repo Control

This repo does not by itself fix:

- OCI instance launch floor
- Karpenter/KPO orchestration delay before instance launch
- OCI native pod networking convergence after node registration

In practice, the remaining dominant delay is usually:

- `Registered -> Initialized`

which is the CNI-ready gate, not Ubuntu package installation.

## What To Read First

If you are new to the repo, read in this order:

1. `README.md`
2. `docs/how-this-actually-works.md`
3. `packer/image.pkr.hcl`
4. `packer/dev.pkrvars.hcl.example`
5. `scripts/install-oke-node-packages.sh`
6. `scripts/lib/prepull.sh`
