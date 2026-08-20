#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/lib/common.sh"

assert_linux_x86_64
aosp_root="${1:-${AOSP_WORKSPACE:-}}"
[[ -n "$aosp_root" ]] || die "usage: $0 /absolute/path/to/aosp-workspace"
assert_aosp_root "$aosp_root"
"${SCRIPT_DIR}/verify-source.sh" "$aosp_root"
assert_clean_git_tree "${aosp_root}/common"
[[ ! -e "${aosp_root}/KernelSU" ]] || die "baseline must be built before KernelSU integration"
[[ ! -e "${aosp_root}/common/drivers/kernelsu" ]] || die "baseline source contains KernelSU integration"

out_root="${OUT_ROOT:-${aosp_root}/out-6sp}"
out_dir="${out_root}/baseline"
dist_dir="${out_root}/dist-baseline"
lto_mode="${LTO_MODE:-$(json_value "${PROJECT_ROOT}/locks/build-lock.json" kernel.lto)}"
build_config="$(json_value "${PROJECT_ROOT}/locks/build-lock.json" kernel.build_config)"
[[ "$lto_mode" == "thin" || "$lto_mode" == "full" ]] || die "LTO_MODE must be thin or full"
mkdir -p -- "$out_dir" "$dist_dir"

log "building exact unmodified baseline with ${lto_mode} LTO"
(
  cd -- "$aosp_root"
  LTO="$lto_mode" \
  BUILD_CONFIG="$build_config" \
  OUT_DIR="$out_dir" \
  DIST_DIR="$dist_dir" \
  build/build.sh
)

[[ -f "${dist_dir}/Image" ]] || die "baseline Image not produced"
assert_lto_config "${out_dir}/common/.config" "$lto_mode"
assert_kernel_release "${out_dir}/common/include/config/kernel.release"
log "baseline build complete: ${dist_dir}"
