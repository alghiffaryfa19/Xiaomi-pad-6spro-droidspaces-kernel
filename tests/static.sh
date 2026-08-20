#!/usr/bin/env bash

set -Eeuo pipefail
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${TEST_DIR}/.." && pwd -P)"

while IFS= read -r script; do
  bash -n "$script"
done < <(find "${PROJECT_ROOT}/scripts" "${PROJECT_ROOT}/tests" -type f -name '*.sh' -print | sort)

(
  SCRIPT_DIR="sentinel-script-directory"
  source "${PROJECT_ROOT}/scripts/lib/common.sh"
  [[ "$SCRIPT_DIR" == "sentinel-script-directory" ]]
)

python3 - "${PROJECT_ROOT}" <<'PY'
import json
import pathlib
import sys
import xml.etree.ElementTree as ET

root = pathlib.Path(sys.argv[1])
for file in sorted((root / "locks").glob("*.json")):
    json.loads(file.read_text(encoding="utf-8"))
build_lock = json.loads((root / "locks" / "build-lock.json").read_text(encoding="utf-8"))
patch_lock = json.loads((root / "locks" / "patches.lock.json").read_text(encoding="utf-8"))
assert build_lock["kernel"]["lto"] == "thin"
assert (root / "configs" / "scmversion").read_text(encoding="utf-8").strip() == build_lock["kernel"]["scmversion"]
assert build_lock["kernel"]["uname_release"] == build_lock["kernel"]["release"] + build_lock["kernel"]["scmversion"]
assert len(patch_lock["patches"]) == 1
assert patch_lock["patches"][0]["role"] == "primary"
apply_config = (root / "scripts" / "apply-config.sh").read_text(encoding="utf-8")
assert "savedefconfig" in apply_config
assert 'verify-config.sh\" \"${config_out}/.config\" --defconfig' in apply_config
droidspaces_fragment = (root / "configs" / "droidspaces-gki.fragment").read_text(encoding="utf-8")
assert "CONFIG_IP_NF_TARGET_REJECT=y" in droidspaces_fragment
assert "CONFIG_NETFILTER_XT_TARGET_REJECT=y" not in droidspaces_fragment
prepare_custom = (root / "scripts" / "prepare-custom.sh").read_text(encoding="utf-8")
assert 'verify-config.sh\" \"${aosp_root}/common/arch/arm64/configs/gki_defconfig' not in prepare_custom
anykernel = (root / "packaging" / "anykernel.sh").read_text(encoding="utf-8")
assert f'device.name1={build_lock["device"]["codename"]}' in anykernel
assert f'supported.versions={build_lock["device"]["android_release"]}' in anykernel
assert "IS_SLOT_DEVICE=1" in anykernel
assert "BLOCK=boot" in anykernel
assert "split_boot;" in anykernel and "flash_boot;" in anykernel
assert "NO_VBMETA_PARTITION_PATCH=1" in anykernel
system_month = build_lock["device"]["system_security_patch"][:7]
vendor_month = build_lock["device"]["vendor_security_patch"][:7]
assert f"supported.patchlevels={system_month} - {system_month}" in anykernel
assert f"supported.vendorpatchlevels={vendor_month} - {vendor_month}" in anykernel
assert not (root / "packaging" / "version").exists()
ET.parse(root / "manifests" / "OS3.0.304.0-pinned.xml")
print("JSON and XML syntax OK")
PY

"${PROJECT_ROOT}/scripts/verify-locks.sh"
printf 'static checks passed\n'
