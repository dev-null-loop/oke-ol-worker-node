#!/usr/bin/env bash

readonly cri_runtime_socket_candidates=(
  /var/run/crio/crio.sock
  /run/crio/crio.sock
  /run/containerd/containerd.sock
)
readonly cri_service_candidates=(
  crio.service
  containerd.service
  cri-o.service
)
readonly cni_binaries=(
  oci-ipam
  oci-ipvlan
  oci-ptp
)
readonly prepull_runtime_dependencies=(
  crun
  podman
)
readonly removable_prepull_packages=(
  podman
)
readonly cni_seed_image_pattern="oke-public-vcn-native-ip-cni-plugin"
readonly cni_binary_source_candidates=(
  /usr/bin
  /bin
)
readonly cni_binary_target_directories=(
  /opt/cni/bin
  /usr/libexec/cni
)
readonly podman_noise_files=(
  /etc/cni/net.d/87-podman-bridge.conflist
  /etc/cni/net.d/100-crio-bridge.conf
  /etc/cni/net.d/200-loopback.conf
)

find_prepull_image() {
  local pattern="$1"
  local image

  IFS=',' read -r -a prepull_images <<<"$prepull_images_csv"
  for image in "${prepull_images[@]}"; do
    [[ -n "$image" ]] || continue
    if [[ "$image" == *"$pattern"* ]]; then
      printf '%s\n' "$image"
      return 0
    fi
  done

  return 1
}

get_cri_runtime_endpoint() {
  local candidate
  for candidate in "${cri_runtime_socket_candidates[@]}"; do
    if [[ -S "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

get_cri_service_name() {
  local unit
  for unit in "${cri_service_candidates[@]}"; do
    if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "^$unit"; then
      printf '%s\n' "$unit"
      return 0
    fi
  done
  return 1
}

ensure_cri_runtime_for_prepull() {
  local service_name
  sudo systemctl daemon-reload || true

  if ! service_name="$(get_cri_service_name)"; then
    echo "No supported CRI service found for image pre-pull" >&2
    systemctl list-unit-files --type=service | grep -E 'cri|containerd' || true
    return 1
  fi

  if ! sudo systemctl enable --now "$service_name"; then
    echo "Failed to start ${service_name} for image pre-pull" >&2
    sudo systemctl status "$service_name" --no-pager || true
    sudo journalctl -u "$service_name" -n 200 --no-pager || true
    return 1
  fi

  local waited=0
  local max_wait=120
  while (( waited < max_wait )); do
    if get_cri_runtime_endpoint >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done

  echo "Timed out waiting for CRI runtime socket" >&2
  sudo systemctl status "$service_name" --no-pager || true
  sudo journalctl -u "$service_name" -n 200 --no-pager || true
  return 1
}

configure_boot_cri_runtime() {
  local service_name
  if ! service_name="$(get_cri_service_name)"; then
    echo "No supported CRI service found to enable for boot optimization" >&2
    return 0
  fi

  echo "Enabling ${service_name} for earlier boot-time runtime startup"
  sudo systemctl enable "$service_name" || true
}

cleanup_cni_config_noise() {
  local file_name
  for file_name in "${podman_noise_files[@]}"; do
    sudo rm -f "$file_name"
  done
  sudo rm -f /etc/cni/net.d/99-dummy.conf
}

remove_prepull_runtime_artifacts() {
  local service_name
  for service_name in podman.service podman.socket podman-restart.service podman-clean-transient.service; do
    if systemctl list-unit-files "$service_name" --no-legend 2>/dev/null | grep -q "^$service_name"; then
      sudo systemctl disable --now "$service_name" 2>/dev/null || true
      sudo systemctl mask "$service_name" 2>/dev/null || true
    fi
  done

  if (( ${#removable_prepull_packages[@]} > 0 )); then
    sudo dnf remove -y "${removable_prepull_packages[@]}" || true
  fi
}

seed_oci_cni_assets_from_prepulled_image() {
  local runtime_endpoint="$1"
  local cni_image

  if ! cni_image="$(find_prepull_image "$cni_seed_image_pattern")"; then
    echo "OCI CNI image not present in PREPULL_IMAGES; skipping OCI CNI asset pre-seed."
    return 0
  fi

  if ! command -v podman >/dev/null 2>&1; then
    echo "podman is not available; skipping OCI CNI asset pre-seed." >&2
    return 0
  fi

  echo "Pre-seeding OCI CNI host assets from image: ${cni_image}"

  local temp_dir
  temp_dir="$(mktemp -d)"
  local container_id=""

  cleanup_cni_seed() {
    if [[ -n "${container_id:-}" ]]; then
      sudo podman rm -f "$container_id" >/dev/null 2>&1 || true
    fi
    if [[ -n "${temp_dir:-}" ]]; then
      rm -rf "$temp_dir"
    fi
  }

  trap cleanup_cni_seed RETURN

  sudo podman pull "$cni_image" >/dev/null
  container_id="$(sudo podman create "$cni_image")"

  local binary
  for binary in "${cni_binaries[@]}"; do
    local copied=0
    local source_dir
    for source_dir in "${cni_binary_source_candidates[@]}"; do
      if sudo podman cp "${container_id}:${source_dir}/${binary}" "${temp_dir}/${binary}" 2>/dev/null; then
        copied=1
        break
      fi
    done
    if (( copied == 0 )); then
      echo "Failed to locate ${binary} in ${cni_image}" >&2
      return 1
    fi
    local target_dir
    for target_dir in "${cni_binary_target_directories[@]}"; do
      sudo install -m 0755 "${temp_dir}/${binary}" "${target_dir}/${binary}"
      sudo chmod 0755 "${target_dir}/${binary}"
    done
  done

  cat >"${temp_dir}/cni-conf.json" <<'EOF'
{"name":"oci","cniVersion":"0.3.1","plugins":[{"cniVersion":"0.3.1","type":"oci-ipvlan","mode":"l2","ipam":{"type":"oci-ipam"}},{"cniVersion":"0.3.1","type":"oci-ptp","containerInterface":"ptp-veth0","mtu":9000}]}
EOF
  cat >"${temp_dir}/iptables" <<'EOF'
#!/bin/sh
if [ -x /host/sbin/iptables ]; then
chroot /host /sbin/iptables "$@"
elif [ -x /host/usr/local/sbin/iptables ]; then
chroot /host /usr/local/sbin/iptables "$@"
elif [ -x /host/bin/iptables ]; then
chroot /host /bin/iptables "$@"
elif [ -x /host/usr/local/bin/iptables ]; then
chroot /host /usr/local/bin/iptables "$@"
else
chroot /host iptables "$@"
fi
EOF
  cat >"${temp_dir}/ip6tables" <<'EOF'
#!/bin/sh
if [ -x /host/sbin/ip6tables ]; then
chroot /host /sbin/ip6tables "$@"
elif [ -x /host/usr/local/sbin/ip6tables ]; then
chroot /host /usr/local/sbin/ip6tables "$@"
elif [ -x /host/bin/ip6tables ]; then
chroot /host /bin/ip6tables "$@"
elif [ -x /host/usr/local/bin/ip6tables ]; then
chroot /host /usr/local/bin/ip6tables "$@"
else
chroot /host ip6tables "$@"
fi
EOF

  sudo install -m 0644 "${temp_dir}/cni-conf.json" /etc/cni/net.d/10-oci.conflist
  sudo chmod 0644 /etc/cni/net.d/10-oci.conflist
  # A zero-byte CNI file triggers repeated parse errors from CRI-O on boot.
  sudo rm -f /etc/cni/net.d/99-dummy.conf

  local file_name
  for file_name in cni-conf.json iptables ip6tables; do
    sudo install -m 0644 "${temp_dir}/${file_name}" "/etc/oci-cni/${file_name}"
  done
  sudo chmod 0644 /etc/oci-cni/cni-conf.json
  sudo chmod 0755 /etc/oci-cni/iptables /etc/oci-cni/ip6tables
  cleanup_cni_config_noise

  echo "OCI CNI host assets pre-seeded successfully."
}

prepull_container_images() {
  [[ -n "$prepull_images_csv" ]] || return 0

  if ! command -v crictl >/dev/null 2>&1; then
    echo "crictl is required for image pre-pull" >&2
    return 1
  fi

  if ! ensure_cri_runtime_for_prepull; then
    echo "Image pre-pull failed because runtime startup failed." >&2
    return 1
  fi

  local runtime_endpoint
  runtime_endpoint="$(get_cri_runtime_endpoint)"
  echo "Using CRI runtime endpoint: ${runtime_endpoint}"

  IFS=',' read -r -a prepull_images <<<"$prepull_images_csv"
  for image in "${prepull_images[@]}"; do
    [[ -n "$image" ]] || continue
    echo "Pre-pulling image: ${image}"
    sudo crictl --runtime-endpoint="$runtime_endpoint" pull "$image"
  done

  echo "Verifying pre-pulled images..."
  sudo crictl --runtime-endpoint="$runtime_endpoint" images

  seed_oci_cni_assets_from_prepulled_image "$runtime_endpoint"

  local service_name
  if service_name="$(get_cri_service_name)"; then
    sudo systemctl stop "$service_name" || true
  fi

  remove_prepull_runtime_artifacts
}

install_helper_packages_if_needed() {
  [[ -n "$helper_packages_csv" ]] || return 0

  IFS=',' read -r -a helper_packages <<<"$helper_packages_csv"
  if (( ${#helper_packages[@]} == 0 )); then
    return 0
  fi

  local missing_packages=()
  local pkg
  for pkg in "${helper_packages[@]}"; do
    [[ -n "$pkg" ]] || continue
    if ! rpm -q "$pkg" >/dev/null 2>&1; then
      missing_packages+=("$pkg")
    fi
  done

  if (( ${#missing_packages[@]} == 0 )); then
    echo "Helper packages already present: ${helper_packages[*]}"
    return 0
  fi

  echo "Installing missing helper packages: ${missing_packages[*]}"
  sudo dnf install -y "${missing_packages[@]}"
}

install_prepull_runtime_dependencies() {
  local runtime_dependencies=()
  local dependency

  for dependency in "${prepull_runtime_dependencies[@]}"; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
      runtime_dependencies+=("$dependency")
    fi
  done

  if (( ${#runtime_dependencies[@]} == 0 )); then
    return 0
  fi

  echo "Installing missing pre-pull runtime dependencies: ${runtime_dependencies[*]}"
  sudo dnf install -y "${runtime_dependencies[@]}"
}
