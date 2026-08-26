#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/lib/common.sh"
source "${script_dir}/lib/oke-binary-patch.sh"
source "${script_dir}/lib/timing-monitor.sh"
source "${script_dir}/lib/prepull.sh"

readonly expected_os_id="ol"
readonly default_helper_packages=(
  jq
  curl
  crictl
)
readonly expected_ol_major_version="${EXPECTED_OL_MAJOR_VERSION:-8}"
helper_packages_csv="$(IFS=,; echo "${default_helper_packages[*]}")"
prepull_images_csv="${PREPULL_IMAGES:-}"

load_os_release() {
  local os_release_path="/etc/os-release"
  if [[ ! -f "$os_release_path" ]]; then
    echo "${os_release_path} is missing" >&2
    exit 1
  fi
  . "$os_release_path"
}

assert_oke_base_image() {
  if [[ "${ID:-}" != "$expected_os_id" ]]; then
    echo "Expected an Oracle Linux base image, found ID=${ID:-unknown}" >&2
    exit 1
  fi

  if [[ "${expected_ol_major_version}" != "8" && "${expected_ol_major_version}" != "9" ]]; then
    echo "Expected Oracle Linux major version must be 8 or 9, found ${expected_ol_major_version}" >&2
    exit 1
  fi

  if [[ "${VERSION_ID:-}" != "${expected_ol_major_version}"* ]]; then
    echo "Expected Oracle Linux ${expected_ol_major_version}, found VERSION_ID=${VERSION_ID:-unknown}" >&2
    exit 1
  fi
}

load_os_release
assert_oke_base_image

expand_root_filesystem_if_possible
prepare_cni_host_paths
install_cni_dummy_guard
disable_wait_online_services
install_cloud_init_optimization_profile
optimize_grub_cmdline_for_local_boot
disable_nonessential_boot_services
refresh_dnf_metadata
patch_oke_bootstrap_backoff
sudo systemctl daemon-reload || true
install_helper_packages_if_needed
install_prepull_runtime_dependencies

sudo systemctl enable oke.service || true
prepare_node_doctor_runtime
configure_boot_cri_runtime
prepull_container_images
install_bootstrap_timing_monitor
sanitize_guest_state

echo "Prepared Oracle Linux ${expected_ol_major_version} OKE worker image from ${ID:-unknown} ${VERSION_ID:-unknown}"
