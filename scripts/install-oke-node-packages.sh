#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/lib/common.sh"
source "${script_dir}/lib/timing-monitor.sh"
source "${script_dir}/lib/prepull.sh"

readonly expected_os_id="ol"
readonly default_helper_packages=(
  jq
  curl
  crictl
)
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

assert_ol8_oke_base_image() {
  if [[ "${ID:-}" != "$expected_os_id" ]]; then
    echo "Expected an Oracle Linux base image, found ID=${ID:-unknown}" >&2
    exit 1
  fi

  if [[ "${VERSION_ID:-}" != 8* ]]; then
    echo "Expected Oracle Linux 8, found VERSION_ID=${VERSION_ID:-unknown}" >&2
    exit 1
  fi
}

load_os_release
assert_ol8_oke_base_image

prepare_cni_host_paths
disable_wait_online_services
optimize_grub_cmdline_for_local_boot
disable_nonessential_boot_services
refresh_dnf_metadata
sudo systemctl daemon-reload || true
install_helper_packages_if_needed
install_prepull_runtime_dependencies

sudo systemctl enable oke.service || true
prepare_node_doctor_runtime
configure_boot_cri_runtime
prepull_container_images
install_bootstrap_timing_monitor
sanitize_guest_state

echo "Prepared Oracle Linux 8 OKE worker image from ${ID:-unknown} ${VERSION_ID:-unknown}"
