#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/lib/common.sh"

assert_linux_x86_64
aosp_root="${1:-${AOSP_WORKSPACE:-}}"
[[ -n "$aosp_root" ]] || die "usage: $0 /absolute/path/to/aosp-workspace"
assert_aosp_root "$aosp_root"
"${SCRIPT_DIR}/verify-source.sh" "$aosp_root"

expected_ksu="$(json_value "${PROJECT_ROOT}/locks/dependencies.lock.json" dependencies.kernelsu.commit)"
[[ -d "${aosp_root}/KernelSU/.git" ]] || die "KernelSU has not been integrated"
[[ "$(git -C "${aosp_root}/KernelSU" rev-parse HEAD)" == "$expected_ksu" ]] || die "workspace KernelSU commit mismatch"
patch_file="${PROJECT_ROOT}/$(json_value "${PROJECT_ROOT}/locks/patches.lock.json" patches.0.path)"
git -C "${aosp_root}/common" apply --reverse --check "$patch_file" >/dev/null 2>&1 || die "Droidspaces patch is not applied"

out_root="${OUT_ROOT:-${aosp_root}/out-6sp}"
out_dir="${out_root}/custom"
dist_dir="${out_root}/dist-custom"
lto_mode="${LTO_MODE:-$(json_value "${PROJECT_ROOT}/locks/build-lock.json" kernel.lto)}"
build_config="$(json_value "${PROJECT_ROOT}/locks/build-lock.json" kernel.build_config)"
[[ "$lto_mode" == "thin" || "$lto_mode" == "full" ]] || die "LTO_MODE must be thin or full"
mkdir -p -- "$out_dir" "$dist_dir"

target="$(json_value "${PROJECT_ROOT}/locks/build-lock.json" target)"
log "building ${target} with ${lto_mode} LTO"
(
  cd -- "$aosp_root"
  LTO="$lto_mode" \
  BUILD_CONFIG="$build_config" \
  OUT_DIR="$out_dir" \
  DIST_DIR="$dist_dir" \
  build/build.sh
)

[[ -f "${dist_dir}/Image" ]] || die "custom Image not produced"
config_path=""
for candidate in "${out_dir}/common/.config" "${out_dir}/.config"; do
  if [[ -f "$candidate" ]]; then
    config_path="$candidate"
    break
  fi
done
[[ -n "$config_path" ]] || die "final .config not found under ${out_dir}"
"${SCRIPT_DIR}/verify-config.sh" "$config_path" --final "$lto_mode"
assert_kernel_release "${out_dir}/common/include/config/kernel.release"
log "custom build complete: ${dist_dir}"
