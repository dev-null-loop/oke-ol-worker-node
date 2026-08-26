#!/usr/bin/env bash

readonly wait_online_units=(
  systemd-networkd-wait-online.service
  NetworkManager-wait-online.service
)
readonly cni_host_directories=(
  /opt/cni/bin
  /usr/libexec/cni
  /etc/cni/net.d
  /etc/oci-cni
)
readonly removable_boot_kernel_args=(
  netroot=iscsi
  rd.iscsi.firmware=1
  rd.iscsi.param=node.session.timeo.replacement_timeout=6000
  libiscsi.debug_libiscsi_eh=1
  rd.net.timeout.carrier=5
  rd.net.timeout.dhcp=10
)
readonly nonessential_boot_units=(
  atd.service
  kdump.service
  ksplice-prefetch.service
  ksplice.service
  libstoragemgmt.service
  mcelog.service
  mdmonitor.service
  multipathd.service
  nis-domainname.service
  nfs_client_id.service
  pmcd.service
  pmie.service
  rpcbind.service
  smartd.service
  sssd.service
  sysstat.service
  tuned.service
  udisks2.service
  vdo.service
  unified-monitoring-agent.service
  unified-monitoring-agent_config_downloader.service
  unified-monitoring-agent_restarter.path
  unified-monitoring-agent_config_downloader.timer
)
readonly node_doctor_root="/usr/lib/oke-node-doctor"
readonly node_doctor_script="/usr/bin/node-doctor.sh"
readonly node_doctor_venv="${node_doctor_root}/venv"
readonly cni_dummy_guard_script="/usr/local/bin/oke-cni-dummy-guard.sh"
readonly cni_dummy_guard_service="/etc/systemd/system/oke-cni-dummy-guard.service"
readonly cni_dummy_guard_path="/etc/systemd/system/oke-cni-dummy-guard.path"
readonly cloud_init_optimization_cfg="/etc/cloud/cloud.cfg.d/98-oke-fast-start.cfg"

refresh_dnf_metadata() {
  sudo dnf makecache --refresh -y
}

optimize_grub_cmdline_for_local_boot() {
  if ! command -v grubby >/dev/null 2>&1; then
    echo "grubby not found; skipping kernel cmdline optimization." >&2
    return 0
  fi

  local remove_args
  remove_args="$(IFS=' '; echo "${removable_boot_kernel_args[*]}")"
  if [[ -n "$remove_args" ]]; then
    echo "Removing unneeded network/iSCSI boot args: ${remove_args}"
    sudo grubby --update-kernel=ALL --remove-args="$remove_args" || true
  fi
}

disable_nonessential_boot_services() {
  local unit
  for unit in "${nonessential_boot_units[@]}"; do
    if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "^$unit"; then
      echo "Disabling ${unit} to reduce worker boot overhead"
      sudo systemctl disable --now "$unit" 2>/dev/null || true
      sudo systemctl mask "$unit" 2>/dev/null || true
    fi
  done
}

prepare_node_doctor_runtime() {
  if [[ ! -f "${node_doctor_root}/requirements-vendored.txt" || ! -f "${node_doctor_script}" ]]; then
    echo "Node doctor artifacts not present; skipping node doctor pre-bake."
    return 0
  fi

  if [[ -x "${node_doctor_venv}/bin/python" ]]; then
    echo "Node doctor virtualenv already present."
  else
    echo "Pre-baking node doctor virtualenv."
    sudo rm -rf "${node_doctor_venv}"
    local workdir
    workdir="$(mktemp -d)"
    trap 'sudo rm -rf "${workdir}"' RETURN

    if ! sudo cp -R "${node_doctor_root}/." "${workdir}/"; then
      echo "Unable to stage node doctor sources." >&2
      return 1
    fi

    if ! sudo python3 -m venv --copies "${workdir}/venv"; then
      echo "Unable to create node doctor virtualenv." >&2
      return 1
    fi

    if sudo "${workdir}/venv/bin/python" -c "import sys; raise SystemExit(0 if (3, 7) <= sys.version_info < (3, 12) else 1)"; then
      if ! sudo "${workdir}/venv/bin/python" -m pip install -q \
        "${workdir}/vendor/pip-22.3.1-whl/pip-22.3.1-py3-none-any.whl" \
        --ignore-installed \
        --disable-pip-version-check; then
        echo "Unable to install bundled pip for node doctor." >&2
        return 1
      fi
    fi

    if ! sudo bash -lc "cd '${workdir}' && '${workdir}/venv/bin/python' -m pip install -q \
      -r ./requirements-vendored.txt \
      --ignore-installed \
      --disable-pip-version-check \
      --no-index \
      --find-links=./vendor/python-dependencies"; then
      echo "Unable to pre-install node doctor dependencies." >&2
      return 1
    fi

    if ! sudo mv "${workdir}/venv" "${node_doctor_venv}"; then
      echo "Unable to move prebaked node doctor virtualenv into place." >&2
      return 1
    fi
  fi

  echo "Patching node doctor launcher to reuse prebaked virtualenv."
  sudo tee "${node_doctor_script}" >/dev/null <<EOF
#!/usr/bin/bash
set -euo pipefail

readonly LOCATION="${node_doctor_root}"
readonly VENV="${node_doctor_venv}"

if [[ \$EUID -ne 0 ]]; then
  echo "WARNING: Node doctor can be only run as root user"
  exit 1
fi

if [[ ! -x "\${VENV}/bin/python" ]]; then
  echo "ERROR: Node doctor virtual environment is missing at \${VENV}" >&2
  exit 1
fi

cd "\${LOCATION}"
exec "\${VENV}/bin/python" -m scripts.main "\$@"
EOF
  sudo chmod 0755 "${node_doctor_script}"
}

prepare_cni_host_paths() {
  sudo install -d -m 0755 "${cni_host_directories[@]}"
  sudo touch /run/xtables.lock
}

expand_root_filesystem_if_possible() {
  if [[ -x /usr/libexec/oci-growfs ]]; then
    echo "Expanding root filesystem during image build with oci-growfs"
    sudo /usr/libexec/oci-growfs -y || true
    return 0
  fi

  echo "No supported root filesystem grow helper found; leaving rootfs expansion to first boot."
}

install_cni_dummy_guard() {
  sudo tee "${cni_dummy_guard_script}" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

dummy_conf="/etc/cni/net.d/99-dummy.conf"

if [[ -e "${dummy_conf}" ]] && [[ ! -s "${dummy_conf}" ]]; then
  rm -f "${dummy_conf}"
fi
EOF
  sudo chmod 0755 "${cni_dummy_guard_script}"

  sudo tee "${cni_dummy_guard_service}" >/dev/null <<EOF
[Unit]
Description=Remove empty OKE dummy CNI config if recreated

[Service]
Type=oneshot
ExecStart=${cni_dummy_guard_script}
EOF

  sudo tee "${cni_dummy_guard_path}" >/dev/null <<EOF
[Unit]
Description=Watch for empty OKE dummy CNI config recreation

[Path]
PathExists=/etc/cni/net.d/99-dummy.conf
Unit=$(basename "${cni_dummy_guard_service}")

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload || true
  sudo systemctl enable "${cni_dummy_guard_path}" || true
}

disable_wait_online_services() {
  local unit

  for unit in "${wait_online_units[@]}"; do
    if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "^$unit"; then
      echo "Masking ${unit} to avoid boot-time wait-online delays"
      sudo systemctl disable --now "$unit" 2>/dev/null || true
      sudo systemctl mask "$unit" || true
    fi
  done
}

install_cloud_init_optimization_profile() {
  sudo tee "${cloud_init_optimization_cfg}" >/dev/null <<'EOF'
# Trim cloud-init work to the modules still needed for OKE worker bootstrap.
# Keep runcmd/scripts-user because the managed and self-managed payloads use them.
cloud_config_modules:
  - mounts
  - locale
  - set-passwords
  - yum-add-repo
  - disable-ec2-metadata
  - runcmd

cloud_final_modules:
  - scripts-user
EOF
}

sanitize_guest_state() {
  echo "Sanitizing guest state before image capture..."

  sudo dnf clean all || true
  sudo rm -rf /var/cache/dnf
  sudo rm -rf /tmp/* /var/tmp/*

  # Reset cloud-init instance state so cloned nodes re-run first-boot logic.
  if command -v cloud-init >/dev/null 2>&1; then
    sudo cloud-init clean --logs || true
  fi
  sudo rm -rf /var/lib/cloud/instance \
              /var/lib/cloud/instances/*

  # Clear machine identity so future boots regenerate per-instance values.
  sudo truncate -s 0 /etc/machine-id
  if [[ -f /var/lib/dbus/machine-id ]]; then
    sudo truncate -s 0 /var/lib/dbus/machine-id
  fi

  sudo find /var/log -type f -exec truncate -s 0 {} \; 2>/dev/null || true
}
