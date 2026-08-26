#!/usr/bin/env bash

readonly oke_binary_path="/usr/bin/oke"

patch_oke_bootstrap_backoff() {
  if [[ ! -x "$oke_binary_path" ]]; then
    echo "Skipping OKE bootstrap patch: ${oke_binary_path} is missing"
    return 0
  fi

  local actual_sha256
  actual_sha256="$(sudo sha256sum "$oke_binary_path" | awk '{print $1}')"
  local patch_rc=0
  if ! sudo OKE_BINARY_SHA256="$actual_sha256" python3 - <<'PY'
import os
from pathlib import Path

path = Path("/usr/bin/oke")
data = bytearray(path.read_bytes())
actual_sha256 = os.environ["OKE_BINARY_SHA256"]

old_backoff = bytes.fromhex("00f2052a01000000")  # 5s
new_backoff = bytes.fromhex("00ca9a3b00000000")  # 1s

offsets_by_sha256 = {
    "4f320a597ce905d5bf2c66279ea1d6a2d099b94e784c312b336109148bdc8210": [
        0xA0A0B6,
        0xA0A15B,
        0xA0A2E5,
        0xA0A63A,
        0xA0AD27,
    ],
    "567808cc6e59b8e3e87e73d5a73ef8f8b9f2b145dca7ab8be495c2c40140a5ee": [
        0xA0A2FF,
        0xA0A416,
        0xA0A557,
        0xA0AFA3,
        0xA1BD36,
    ],
}

offsets = offsets_by_sha256.get(actual_sha256)
if offsets is None:
    raise SystemExit(100)

for offset in offsets:
    current = bytes(data[offset:offset + len(old_backoff)])
    if current != old_backoff:
        raise SystemExit(
            f"unexpected bytes at {offset:#x}: {current.hex()} != {old_backoff.hex()}"
        )
    data[offset:offset + len(old_backoff)] = new_backoff

path.write_bytes(data)
PY
  then
    patch_rc=$?
  fi
  if [[ $patch_rc -eq 100 ]]; then
    echo "Skipping OKE bootstrap patch: unsupported /usr/bin/oke sha256 ${actual_sha256}"
    return 0
  fi
  if [[ $patch_rc -ne 0 ]]; then
    return $patch_rc
  fi

  echo "Patched OKE bootstrap exponential-backoff cap from 5s to 1s for sha256 ${actual_sha256}"
}
