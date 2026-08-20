#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/lib/common.sh"

aosp_root="${1:-${AOSP_WORKSPACE:-}}"
[[ -n "$aosp_root" ]] || die "usage: $0 /absolute/path/to/aosp-workspace"
assert_aosp_root "$aosp_root"

config_tool="${aosp_root}/common/scripts/config"
defconfig="${aosp_root}/common/arch/arm64/configs/gki_defconfig"
[[ -x "$config_tool" ]] || die "kernel scripts/config is unavailable"
[[ -f "$defconfig" ]] || die "gki_defconfig is unavailable"
[[ -L "${aosp_root}/common/drivers/kernelsu" ]] || die "integrate KernelSU before applying CONFIG_KSU"
require_command make

kernel_constants="${aosp_root}/common/build.config.constants"
[[ -f "$kernel_constants" ]] || die "kernel build constants are unavailable"
kernel_clang_version="$(sed -n 's/^CLANG_VERSION=//p' "$kernel_constants")"
[[ -n "$kernel_clang_version" ]] || die "CLANG_VERSION is missing from build.config.constants"
kernel_clang_bin="${aosp_root}/prebuilts/clang/host/linux-x86/clang-${kernel_clang_version}/bin"
[[ -x "${kernel_clang_bin}/clang" ]] || die "pinned clang is unavailable: ${kernel_clang_bin}"
export PATH="${kernel_clang_bin}:${PATH}"

apply_fragment() {
  local fragment="$1"
  while IFS= read -r line; do
    case "$line" in
      CONFIG_*=y)
        symbol="${line%%=*}"
        "$config_tool" --file "$defconfig" -e "${symbol#CONFIG_}"
        ;;
      '# CONFIG_'*' is not set')
        symbol="${line#\# CONFIG_}"
        symbol="${symbol% is not set}"
        "$config_tool" --file "$defconfig" -d "$symbol"
        ;;
      ''|'#'*) ;;
      *) die "unsupported fragment line in ${fragment}: ${line}" ;;
    esac
  done < "$fragment"
}

apply_fragment "${PROJECT_ROOT}/configs/droidspaces-gki.fragment"
apply_fragment "${PROJECT_ROOT}/configs/kernelsu.fragment"

# AOSP's build checks that the checked-in defconfig is the exact minimal,
# canonical output of savedefconfig. scripts/config deliberately appends new
# symbols, so normalize the file before handing it to build/build.sh.
config_out="$(mktemp -d "${TMPDIR:-/tmp}/6sp-config.XXXXXX")"
cleanup() {
  rm -rf -- "$config_out"
}
trap cleanup EXIT

make -s -C "${aosp_root}/common" \
  O="$config_out" ARCH=arm64 LLVM=1 gki_defconfig
make -s -C "${aosp_root}/common" \
  O="$config_out" ARCH=arm64 LLVM=1 savedefconfig
install -m 0644 -- "${config_out}/defconfig" "$defconfig"

# Validate the expanded configuration rather than requiring default-valued
# symbols (for example CONFIG_KSU=y) to remain in minimal savedefconfig output.
make -s -C "${aosp_root}/common" \
  O="$config_out" ARCH=arm64 LLVM=1 gki_defconfig
"${SCRIPT_DIR}/verify-config.sh" "${config_out}/.config" --defconfig
log "updated and canonicalized gki_defconfig idempotently"
