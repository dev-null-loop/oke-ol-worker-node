# oke-ol-worker-node

Build an OCI custom image for OKE Oracle Linux 8 or Oracle Linux 9 worker nodes with Packer.

The image is referenced at runtime from `private-oke-karpenter` through `OCINodeClass.imageId`.

## Inputs

Set local values in `packer/dev.pkrvars.hcl`:

Required:

- `availability_domain`
- `compartment_ocid`
- `subnet_ocid`
- `base_image_ocid`
- `oracle_linux_major_version`
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
- `oracle_linux_major_version`
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

1. start from an official OKE Oracle Linux worker image that matches the requested major version
2. install `jq`, `curl`, and `crictl`
3. pre-create OCI CNI host directories
4. expand the root filesystem during image build when the helper is available
5. mask wait-online services
6. patch the known `oke` bootstrap binary to lower hardcoded exponential-backoff caps from `5s` to `1s`
7. enable the CRI service at boot
8. pre-pull the configured image set
9. pre-seed OCI CNI host assets when the OCI CNI image is included
10. remove podman and stray CNI configs after pre-seed
11. install the bootstrap timing monitor
12. sanitize guest state before image capture

## Implemented Optimizations

1. use the official OKE Oracle Linux worker image as the base
2. bake in bootstrap helper tools: `jq`, `curl`, `crictl`
3. pre-create OCI CNI host paths:
   - `/opt/cni/bin`
   - `/usr/libexec/cni`
   - `/etc/cni/net.d`
   - `/etc/oci-cni`
4. expand the root filesystem during image build with `/usr/libexec/oci-growfs` when present
5. mask `wait-online` services to avoid unnecessary boot blocking
6. patch the known August 25, 2026 `oke` bootstrap binary in-image by SHA-256 guard to reduce hardcoded backoff caps
7. enable the CRI runtime and `oke.service` for earlier boot-time startup
8. pre-pull the standard first-boot OKE image set into the image
9. pre-seed OCI CNI host assets from the OCI CNI image:
   - CNI binaries
   - OCI CNI config
   - supporting iptables assets
10. remove podman after pre-seed and delete stray CNI files such as `87-podman-bridge.conflist`, `100-crio-bridge.conf`, `200-loopback.conf`, and `99-dummy.conf`
11. install a bootstrap timing monitor that writes `/var/log/oke-optimized-bootstrap-timing.log`
12. sanitize guest state before image capture

## Benchmark Findings

- baseline 100-node VCN-native run with the earlier single `cni-ready-untaint` deployment stalled at `99/100` and reached that point at about `558s`
- replacing the single untaint deployment with a per-node `DaemonSet` materially improved the tail
- rerun with the per-node helper reached `99/100` at about `261s`
- the remaining gap was not image boot or CNI image pull time
- the last blocker was one launched instance that never registered as a Kubernetes node until it was patched manually

## Registered-Node Failure Found

One failed node from the 100-node rerun was inspected directly.

Observed state on the broken node:

- OCI instance was `RUNNING`
- `crio` and `kubelet` were `active`
- the node could reach `https://10.0.0.11:6443`
- `/var/lib/kubelet/pki/kubelet-client-current.pem` was missing
- kubelet registration and CSR submission were failing with `Unauthorized`

Observed auth mismatch:

- `/etc/kubernetes/bootstrap-kubelet.conf` on the node contained token `qorysq.korf64ruzp4heeew`
- the live cluster secret `bootstrap-token-qorysq` contained token secret `uooab4bheyk91zpx`
- there was no CSR in the cluster for `system:bootstrap:qorysq`
- after replacing the on-node token with the live secret value and restarting `kubelet`, the node registered immediately

Current conclusion:

- the image and the `metadata.user_data` wrapper were not the source of this failure
- the token mismatch appears after the node calls the OKE worker bootstrap endpoint and before kubelet successfully bootstraps
- the remaining intermittent `99/100` issue is a bootstrap-token mismatch or stale bootstrap-config issue in the OKE/KPO control path, not a guest boot-time regression in this repo

## Defaults and Built Image Contents

- Oracle Linux 8 or Oracle Linux 9 OKE image
- shape defaults to `VM.Standard.E5.Flex` with `1` OCPU and `12` GB RAM
- image metadata tags for `k8s_version`, base image, and profile
- helper packages baked in: `jq`, `curl`, `crictl`
- CRI runtime enabled for earlier boot-time startup
- CNI host paths pre-created in the image
- bootstrap timing monitor enabled
- image name is `ol<major>-YYYY.MM.DD-OKE-<k8s_version>-<optimization_profile>`
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
  - validates the requested Oracle Linux base image major version
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
- `scripts/install-oke-node-packages.sh`: installs OKE Oracle Linux worker packages into the image
- `scripts/lib/common.sh`: apt locking, guest cleanup, and wait-online handling
- `scripts/lib/prepull.sh`: CRI startup, image pre-pull, and OCI CNI asset seeding
- `scripts/lib/timing-monitor.sh`: bootstrap timing monitor installation
- `cloud-init/managed-minimal.yaml`: managed node bootstrap
- `cloud-init/self-managed-minimal.yaml`: self-managed node bootstrap
