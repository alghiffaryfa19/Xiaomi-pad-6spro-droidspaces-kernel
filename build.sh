#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
BUILD_DIR="$ROOT/build"
RELEASE_DIR=${RELEASE_DIR:-"$ROOT/releases"}

# shellcheck source=build/config.env
source "$BUILD_DIR/config.env"

RESUKISU_COMMIT=
RESUKISU_RELEASE_TAG=
RESUKISU_RELEASE_URL=

# Required and recommended GKI settings from the Droidspaces kernel guide,
# plus ReSukiSU and Xiaomi vendor-module compatibility settings.
readonly -a ENABLED_CONFIGS=(
  SYSVIPC POSIX_MQUEUE IPC_NS PID_NS DEVTMPFS NETFILTER_XT_MATCH_ADDRTYPE
  USER_NS UTS_NS NET_NS CGROUP_DEVICE CGROUP_FREEZER IP_NF_TARGET_REJECT
  NETFILTER_XT_TARGET_LOG NETFILTER_XT_MATCH_RECENT
  IP_SET IP_SET_HASH_IP IP_SET_HASH_NET NETFILTER_XT_SET
  TMPFS_POSIX_ACL TMPFS_XATTR
  KSU
  MODULE_ALLOW_BTF_MISMATCH
  DRM_LINDROID_EVDI
  VT DUMMY_CONSOLE
)
readonly -a DISABLED_CONFIGS=(
  KSU_DEBUG KSU_TOOLKIT_SUPPORT KSU_DISABLE_MANAGER KSU_DISABLE_POLICY
  KSU_MULTI_MANAGER_SUPPORT
)

log() { printf '[6sp] %s\n' "$*"; }
die() { printf '[6sp] ERROR: %s\n' "$*" >&2; exit 1; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing host tool: $1"
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
  for command in git repo rsync zip unzip make curl jq patch perl file bc bison flex openssl realpath sha256sum; do
    require_command "$command"
  done
}

resolve_resukisu_release() {
  local response
  local -a curl_args=(
    -fsSL --retry 3
    -H 'Accept: application/vnd.github+json'
    -H 'X-GitHub-Api-Version: 2022-11-28'
  )

  if [[ -n ${GITHUB_TOKEN:-} ]]; then
    curl_args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi
  response=$(curl "${curl_args[@]}" "$RESUKISU_RELEASES_API?per_page=1") ||
    die "failed to query ReSukiSU releases"
  RESUKISU_RELEASE_TAG=$(jq -er 'first.tag_name' <<< "$response") ||
    die "ReSukiSU release tag is missing"
  RESUKISU_RELEASE_URL=$(jq -er 'first.html_url' <<< "$response") ||
    die "ReSukiSU release URL is missing"
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

fetch_dependencies() {
  local workspace=$1 resukisu="$1/ReSukiSU"
  local anykernel="$TEMP_DIR/AnyKernel3"

  git clone --filter=blob:none --branch "$RESUKISU_RELEASE_TAG" \
    "$RESUKISU_REPOSITORY" "$resukisu"
  RESUKISU_COMMIT=$(git -C "$resukisu" rev-parse HEAD)

  git init -q "$anykernel"
  git -C "$anykernel" fetch --depth=1 --no-tags "$AK3_REPOSITORY" "$AK3_COMMIT"
  git -C "$anykernel" checkout --detach FETCH_HEAD
  [[ $(git -C "$anykernel" rev-parse HEAD) == "$AK3_COMMIT" ]] ||
    die "unexpected AnyKernel3 revision"

  log "ReSukiSU: $RESUKISU_RELEASE_TAG ($RESUKISU_COMMIT)"
}

integrate_resukisu() {
  local common="$1/common" link="$1/common/drivers/kernelsu" marker

  ln -s ../../ReSukiSU/kernel "$link"
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$common/drivers/Makefile"
  marker=$(grep -n '^endmenu$' "$common/drivers/Kconfig" | tail -n 1 | cut -d: -f1)
  [[ -n "$marker" ]] || die "drivers/Kconfig has no endmenu marker"
  sed -i "${marker}i source \"drivers/kernelsu/Kconfig\"" "$common/drivers/Kconfig"
}

integrate_lindroid() {
  local common="$1/common" marker

  git clone https://github.com/Linux-on-droid/lindroid-drm-loopback "$common/drivers/lindroid-drm"
  printf '\nobj-y += lindroid-drm/\n' >> "$common/drivers/Makefile"
  marker=$(grep -n '^endmenu$' "$common/drivers/Kconfig" | tail -n 1 | cut -d: -f1)
  [[ -n "$marker" ]] || die "drivers/Kconfig has no endmenu marker"
  sed -i "${marker}i source \"drivers/lindroid-drm/Kconfig\"" "$common/drivers/Kconfig"
}



prepare_sources() {
  local workspace=$1 common="$1/common" defconfig tool constants clang_version
  local clang_bin build_tools pahole config_out symbol

  printf '%s\n' "$SCMVERSION" > "$common/.scmversion"
  git -C "$common" apply --check "$BUILD_DIR/kabi.patch"
  git -C "$common" apply "$BUILD_DIR/kabi.patch"
  integrate_resukisu "$workspace"
  integrate_lindroid "$workspace"

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
  local anykernel="$TEMP_DIR/AnyKernel3"
  local staging archive checksum temporary digest artifact_name lto_label
  local resukisu_short=${RESUKISU_COMMIT:0:12}

  lto_label=${LTO_MODE^}
  artifact_name="$TARGET-$resukisu_short"

  staging="$TEMP_DIR/package"
  mkdir -p -- "$staging/META-INF/com/google/android" "$staging/tools" "$RELEASE_DIR"
  cp -- "$anykernel/LICENSE" "$staging/"
  cp -- "$anykernel/META-INF/com/google/android/update-binary" \
    "$anykernel/META-INF/com/google/android/updater-script" \
    "$staging/META-INF/com/google/android/"
  cp -- "$anykernel/tools/ak3-core.sh" "$anykernel/tools/busybox" \
    "$anykernel/tools/magiskboot" "$staging/tools/"
  sed -e "s/@RESUKISU_VERSION@/$RESUKISU_RELEASE_TAG-$resukisu_short/" \
    -e "s/@LTO_LABEL@/$lto_label/" \
    "$BUILD_DIR/anykernel.sh" > "$staging/anykernel.sh"
  cp -- "$image" "$staging/Image"
  printf '%s\n' "$artifact_name" > "$staging/version"

  archive="$RELEASE_DIR/$artifact_name-anykernel3.zip"
  checksum="$RELEASE_DIR/$artifact_name-SHA256SUMS.txt"
  temporary="$TEMP_DIR/$artifact_name-anykernel3.zip"
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
  log "resolving the current ReSukiSU release"
  resolve_resukisu_release
  log "syncing pinned AOSP source"
  sync_sources "$workspace"
  log "fetching dependencies"
  fetch_dependencies "$workspace"
  log "applying Droidspaces and ReSukiSU configuration"
  prepare_sources "$workspace"
  log "building $TARGET with ${LTO_MODE^} LTO"
  build_kernel "$workspace"
  log "packaging AnyKernel3 artifact"
  package_kernel "$workspace"
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    printf '%s\n' \
      '## Build summary' \
      '' \
      "- Kernel \`$KERNEL_RELEASE\`" \
      "- ReSukiSU \`$RESUKISU_RELEASE_TAG\` (\`${RESUKISU_COMMIT:0:12}\`) · [Manager]($RESUKISU_RELEASE_URL)" \
      >> "$GITHUB_STEP_SUMMARY"
  fi
}

TEMP_DIR=$(mktemp -d -t 6sp-build.XXXXXXXX)
trap 'rm -rf -- "$TEMP_DIR"' EXIT
main "$@"
