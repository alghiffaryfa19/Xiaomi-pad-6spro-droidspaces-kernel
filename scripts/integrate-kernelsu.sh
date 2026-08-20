#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/lib/common.sh"

aosp_root="${1:-${AOSP_WORKSPACE:-}}"
[[ -n "$aosp_root" ]] || die "usage: $0 /absolute/path/to/aosp-workspace"
assert_aosp_root "$aosp_root"
require_command git
require_command realpath

lock_file="${PROJECT_ROOT}/locks/dependencies.lock.json"
expected_commit="$(json_value "$lock_file" dependencies.kernelsu.commit)"
source_checkout="${PROJECT_ROOT}/third_party/KernelSU"
destination="${aosp_root}/KernelSU"
driver_dir="${aosp_root}/common/drivers"

[[ -d "${source_checkout}/.git" ]] || die "KernelSU is not fetched; run scripts/fetch-third-party.sh first"
[[ "$(git -C "$source_checkout" rev-parse HEAD)" == "$expected_commit" ]] || die "third-party KernelSU commit mismatch"
assert_clean_git_tree "$source_checkout"

if [[ ! -e "$destination" ]]; then
  git clone --no-hardlinks "$source_checkout" "$destination"
  git -C "$destination" checkout --detach "$expected_commit"
elif [[ -d "${destination}/.git" ]]; then
  [[ "$(git -C "$destination" rev-parse HEAD)" == "$expected_commit" ]] || die "workspace KernelSU commit mismatch"
  assert_clean_git_tree "$destination"
else
  die "refusing to overwrite non-git KernelSU path: ${destination}"
fi

link_target="$(realpath --relative-to="$driver_dir" "${destination}/kernel")"
if [[ -L "${driver_dir}/kernelsu" ]]; then
  [[ "$(readlink "${driver_dir}/kernelsu")" == "$link_target" ]] || die "unexpected drivers/kernelsu symlink"
elif [[ -e "${driver_dir}/kernelsu" ]]; then
  die "drivers/kernelsu exists and is not a symlink"
else
  ln -s "$link_target" "${driver_dir}/kernelsu"
fi

makefile="${driver_dir}/Makefile"
kconfig="${driver_dir}/Kconfig"
make_line='obj-$(CONFIG_KSU) += kernelsu/'
kconfig_line='source "drivers/kernelsu/Kconfig"'

grep -Fqx "$make_line" "$makefile" || printf '\n%s\n' "$make_line" >> "$makefile"
if ! grep -Fqx "$kconfig_line" "$kconfig"; then
  sed -i "/^endmenu$/i\\${kconfig_line}" "$kconfig"
fi

[[ "$(git -C "$destination" rev-parse HEAD)" == "$expected_commit" ]] || die "KernelSU changed during integration"
log "integrated official KernelSU ${expected_commit} without running floating setup logic"

