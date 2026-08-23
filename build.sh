#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
BUILD_DIR="$ROOT/build"
CACHE_DIR=${CACHE_DIR:-"$ROOT/.cache"}
RELEASE_DIR=${RELEASE_DIR:-"$ROOT/releases"}

# shellcheck source=build/config.env
source "$BUILD_DIR/config.env"

# Required and recommended GKI settings from the Droidspaces kernel guide,
# plus the pinned KernelSU and Xiaomi vendor-module compatibility settings.
readonly -a ENABLED_CONFIGS=(
  SYSVIPC POSIX_MQUEUE IPC_NS PID_NS DEVTMPFS NETFILTER_XT_MATCH_ADDRTYPE
  USER_NS IP_NF_TARGET_REJECT NETFILTER_XT_TARGET_LOG NETFILTER_XT_MATCH_RECENT
  IP_SET IP_SET_HASH_IP IP_SET_HASH_NET NETFILTER_XT_SET
  TMPFS_POSIX_ACL TMPFS_XATTR
  KSU MODULE_ALLOW_BTF_MISMATCH
)
readonly -a DISABLED_CONFIGS=(
  KSU_DEBUG KSU_DISABLE_MANAGER KSU_DISABLE_POLICY
)

log() { printf '[6sp] %s\n' "$*"; }
die() { printf '[6sp] ERROR: %s\n' "$*" >&2; exit 1; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing host tool: $1"
}

git_head() {
  git -C "$1" rev-parse HEAD
}

require_commit() {
  [[ -d "$1/.git" ]] || die "not a Git checkout: $1"
  [[ $(git_head "$1") == "$2" ]] || die "unexpected source revision: $1"
}

require_clean() {
  [[ -z "$(git -C "$1" status --porcelain)" ]] ||
    die "dependency checkout is not clean: $1"
}

require_line() {
  grep -Fqx -- "$2" "$1" || die "missing configuration: $2"
}

verify_config() {
  local config=$1 final=${2:-false} symbol

  for symbol in "${ENABLED_CONFIGS[@]}"; do
    require_line "$config" "CONFIG_$symbol=y"
  done
  for symbol in "${DISABLED_CONFIGS[@]}"; do
    require_line "$config" "# CONFIG_$symbol is not set"
  done
  if grep -Eq '^CONFIG_(KSU_SUSFS|SUSFS|NT_SYNC|NTSYNC)=y$' "$config"; then
    die "an unsupported KernelSU extension is enabled"
  fi

  if [[ "$final" == true ]]; then
    require_line "$config" 'CONFIG_MODVERSIONS=y'
    require_line "$config" 'CONFIG_TRIM_UNUSED_KSYMS=y'
    require_line "$config" 'CONFIG_KPROBES=y'
    require_line "$config" 'CONFIG_EXT4_FS=y'
    require_line "$config" 'CONFIG_LTO=y'
    require_line "$config" 'CONFIG_LTO_CLANG=y'
    require_line "$config" 'CONFIG_LTO_CLANG_THIN=y'
    require_line "$config" '# CONFIG_LTO_CLANG_FULL is not set'
  fi
}

check_host() {
  [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] ||
    die "kernel builds require Linux x86_64"

  local command
  for command in git repo rsync zip unzip make perl file bc bison flex openssl realpath sha256sum; do
    require_command "$command"
  done
}

sync_sources() {
  local workspace=$1 manifest=6sp.xml

  mkdir -p -- "$workspace"
  (
    cd "$workspace"
    repo init --depth=1 \
      -u https://android.googlesource.com/kernel/manifest \
      -b "$MANIFEST_COMMIT" \
      --no-clone-bundle --no-tags
    cp -- "$BUILD_DIR/manifest.xml" ".repo/manifests/$manifest"
    repo init --depth=1 -m "$manifest" --no-clone-bundle --no-tags
    repo sync --current-branch --no-clone-bundle --no-tags --fail-fast \
      -j "${SYNC_JOBS:-8}"
  )

  [[ -d "$workspace/common/.git" && -f "$workspace/build/build.sh" ]] ||
    die "AOSP source sync is incomplete"
}

fetch_dependency() {
  local name=$1 repository=$2 commit=$3 checkout="$CACHE_DIR/$1" temporary

  if [[ -e "$checkout" ]]; then
    require_commit "$checkout" "$commit"
    require_clean "$checkout"
    return
  fi

  mkdir -p -- "$CACHE_DIR"
  temporary="$TEMP_DIR/$name"
  git init -q "$temporary"
  git -C "$temporary" remote add origin "$repository"
  git -C "$temporary" fetch --depth=1 --no-tags origin "$commit"
  git -C "$temporary" checkout --detach FETCH_HEAD
  require_commit "$temporary" "$commit"
  mv -- "$temporary" "$checkout"
}

integrate_kernelsu() {
  local common="$1/common" source="$CACHE_DIR/KernelSU"
  local checkout="$1/KernelSU" link="$1/common/drivers/kernelsu" marker

  require_commit "$source" "$KERNELSU_COMMIT"
  require_clean "$source"

  if [[ ! -e "$checkout" ]]; then
    git clone --no-hardlinks "$source" "$checkout"
    git -C "$checkout" checkout --detach "$KERNELSU_COMMIT"
  fi
  require_commit "$checkout" "$KERNELSU_COMMIT"
  require_clean "$checkout"

  if [[ -L "$link" ]]; then
    [[ $(readlink "$link") == ../../KernelSU/kernel ]] ||
      die "unexpected KernelSU symlink: $link"
  elif [[ -e "$link" ]]; then
    die "KernelSU integration path is not a symlink: $link"
  else
    ln -s ../../KernelSU/kernel "$link"
  fi

  grep -Fqx 'obj-$(CONFIG_KSU) += kernelsu/' "$common/drivers/Makefile" ||
    printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$common/drivers/Makefile"

  if ! grep -Fqx 'source "drivers/kernelsu/Kconfig"' "$common/drivers/Kconfig"; then
    marker=$(grep -n '^endmenu$' "$common/drivers/Kconfig" | tail -n 1 | cut -d: -f1)
    [[ -n "$marker" ]] || die "drivers/Kconfig has no endmenu marker"
    sed -i "${marker}i source \"drivers/kernelsu/Kconfig\"" "$common/drivers/Kconfig"
  fi
}

apply_patch() {
  local common=$1 patch="$BUILD_DIR/kabi.patch"

  if git -C "$common" apply --reverse --check "$patch" >/dev/null 2>&1; then
    return
  fi
  git -C "$common" apply --check "$patch"
  git -C "$common" apply "$patch"
}

prepare_sources() {
  local workspace=$1 common="$1/common" defconfig tool constants clang_version
  local clang_bin build_tools pahole config_out symbol

  printf '%s\n' "$SCMVERSION" > "$common/.scmversion"
  apply_patch "$common"
  integrate_kernelsu "$workspace"

  defconfig="$common/arch/arm64/configs/gki_defconfig"
  tool="$common/scripts/config"
  [[ -x "$tool" && -f "$defconfig" ]] || die "kernel configuration tools are missing"

  for symbol in "${ENABLED_CONFIGS[@]}"; do
    "$tool" --file "$defconfig" -e "$symbol"
  done
  for symbol in "${DISABLED_CONFIGS[@]}"; do
    "$tool" --file "$defconfig" -d "$symbol"
  done

  constants="$common/build.config.constants"
  clang_version=$(sed -n 's/^CLANG_VERSION=//p' "$constants" | head -n 1)
  clang_bin="$workspace/prebuilts/clang/host/linux-x86/clang-$clang_version/bin"
  build_tools="$workspace/prebuilts/kernel-build-tools/linux-x86/bin"
  pahole="$build_tools/pahole"
  [[ -x "$clang_bin/clang" && -x "$pahole" ]] ||
    die "pinned AOSP clang or pahole is missing"

  config_out="$TEMP_DIR/config"
  mkdir -p -- "$config_out"
  PATH="$clang_bin:$build_tools:$PATH" PAHOLE="$pahole" \
    make -s -C "$common" O="$config_out" ARCH=arm64 LLVM=1 gki_defconfig
  PATH="$clang_bin:$build_tools:$PATH" PAHOLE="$pahole" \
    make -s -C "$common" O="$config_out" ARCH=arm64 LLVM=1 savedefconfig
  cp -- "$config_out/defconfig" "$defconfig"
  PATH="$clang_bin:$build_tools:$PATH" PAHOLE="$pahole" \
    make -s -C "$common" O="$config_out" ARCH=arm64 LLVM=1 gki_defconfig
  verify_config "$config_out/.config"
}

build_kernel() {
  local workspace=$1 output="$1/out-6sp" build_out dist config release

  build_out="$output/custom"
  dist="$output/dist-custom"
  mkdir -p -- "$build_out" "$dist"
  (
    cd "$workspace"
    LTO="$LTO_MODE" \
      BUILD_CONFIG="$AOSP_BUILD_CONFIG" \
      GKI_BUILD_CONFIG_FRAGMENT="$BUILD_DIR/output.config" \
      OUT_DIR="$build_out" \
      DIST_DIR="$dist" \
      ./build/build.sh
  )

  config="$build_out/common/.config"
  release="$build_out/common/include/config/kernel.release"
  [[ -f "$dist/Image" && -f "$release" ]] || die "kernel build did not produce Image"
  verify_config "$config" true
  [[ $(tr -d '\r\n' < "$release") == "$KERNEL_RELEASE" ]] ||
    die "unexpected kernel release: $(tr -d '\r\n' < "$release")"
}

package_kernel() {
  local workspace=$1 image="$1/out-6sp/dist-custom/Image"
  local anykernel="$CACHE_DIR/AnyKernel3" staging archive checksum temporary digest

  require_commit "$anykernel" "$AK3_COMMIT"
  require_clean "$anykernel"
  [[ -f "$image" ]] || die "kernel Image is missing"

  staging="$TEMP_DIR/package"
  mkdir -p -- "$staging/META-INF/com/google/android" "$staging/tools" "$RELEASE_DIR"
  cp -- "$anykernel/LICENSE" "$staging/"
  cp -- "$anykernel/META-INF/com/google/android/update-binary" \
    "$anykernel/META-INF/com/google/android/updater-script" \
    "$staging/META-INF/com/google/android/"
  cp -- "$anykernel/tools/ak3-core.sh" "$anykernel/tools/busybox" \
    "$anykernel/tools/magiskboot" "$staging/tools/"
  cp -- "$BUILD_DIR/anykernel.sh" "$staging/anykernel.sh"
  cp -- "$image" "$staging/Image"
  printf '%s\n' "$TARGET" > "$staging/version"

  archive="$RELEASE_DIR/$TARGET-anykernel3.zip"
  checksum="$RELEASE_DIR/$TARGET-SHA256SUMS.txt"
  temporary="$TEMP_DIR/$TARGET-anykernel3.zip"
  (cd "$staging" && zip -q -9 -r "$temporary" .)
  unzip -tq "$temporary" >/dev/null
  mv -f -- "$temporary" "$archive"

  digest=$(sha256sum "$archive" | awk '{print $1}')
  printf '%s  %s\n' "$digest" "$(basename "$archive")" > "$checksum"
  log "artifact: $archive"
  log "SHA-256: $digest"
}

main() {
  (($# == 1)) || die "usage: $0 /path/to/aosp-workspace"
  check_host

  local workspace
  workspace=$(realpath -m -- "$1")
  log "syncing pinned AOSP source"
  sync_sources "$workspace"
  log "fetching pinned dependencies"
  fetch_dependency KernelSU "$KERNELSU_REPOSITORY" "$KERNELSU_COMMIT"
  fetch_dependency AnyKernel3 "$AK3_REPOSITORY" "$AK3_COMMIT"
  log "applying Droidspaces and KernelSU configuration"
  prepare_sources "$workspace"
  log "building $TARGET with Thin LTO"
  build_kernel "$workspace"
  log "packaging AnyKernel3 artifact"
  package_kernel "$workspace"
}

TEMP_DIR=$(mktemp -d -t 6sp-build.XXXXXXXX)
trap 'rm -rf -- "$TEMP_DIR"' EXIT
main "$@"
