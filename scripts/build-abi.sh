#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/lib/common.sh"

assert_linux_x86_64
aosp_root="${1:-${AOSP_WORKSPACE:-}}"
variant="${2:-custom}"
[[ -n "$aosp_root" ]] || die "usage: $0 /absolute/path/to/aosp-workspace [baseline|custom]"
[[ "$variant" == "baseline" || "$variant" == "custom" ]] || die "variant must be baseline or custom"
assert_aosp_root "$aosp_root"

if [[ "$variant" == "baseline" ]]; then
  assert_clean_git_tree "${aosp_root}/common"
  [[ ! -e "${aosp_root}/KernelSU" ]] || die "baseline ABI requires unmodified source"
else
  [[ -d "${aosp_root}/KernelSU/.git" ]] || die "custom ABI requires KernelSU integration"
fi

out_root="${OUT_ROOT:-${aosp_root}/out-6sp}"
out_dir="${out_root}/abi-${variant}"
dist_dir="${out_root}/dist-abi-${variant}"
lto_mode="${LTO_MODE:-$(json_value "${PROJECT_ROOT}/locks/build-lock.json" kernel.lto)}"
build_config="$(json_value "${PROJECT_ROOT}/locks/build-lock.json" kernel.build_config)"
[[ "$lto_mode" == "thin" || "$lto_mode" == "full" ]] || die "LTO_MODE must be thin or full"
mkdir -p -- "$out_dir" "$dist_dir"

(
  cd -- "$aosp_root"
  LTO="$lto_mode" \
  BUILD_CONFIG="$build_config" \
  OUT_DIR="$out_dir" \
  DIST_DIR="$dist_dir" \
  build/build_abi.sh
)
assert_lto_config "${out_dir}/common/.config" "$lto_mode"
log "ABI build complete with ${lto_mode} LTO: ${dist_dir}"
