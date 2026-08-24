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
SUSFS_COMMIT=
SUSFS_VERSION=

# Required and recommended GKI settings from the Droidspaces kernel guide,
# plus ReSukiSU, SuSFS and Xiaomi vendor-module compatibility settings.
readonly -a ENABLED_CONFIGS=(
  SYSVIPC POSIX_MQUEUE IPC_NS PID_NS DEVTMPFS NETFILTER_XT_MATCH_ADDRTYPE
  USER_NS IP_NF_TARGET_REJECT NETFILTER_XT_TARGET_LOG NETFILTER_XT_MATCH_RECENT
  IP_SET IP_SET_HASH_IP IP_SET_HASH_NET NETFILTER_XT_SET
  TMPFS_POSIX_ACL TMPFS_XATTR
  KSU KSU_SUSFS
  KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_MOUNT KSU_SUSFS_SUS_KSTAT
  KSU_SUSFS_SPOOF_UNAME KSU_SUSFS_ENABLE_LOG KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
  KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG KSU_SUSFS_OPEN_REDIRECT KSU_SUSFS_SUS_MAP
  MODULE_ALLOW_BTF_MISMATCH
)
readonly -a DISABLED_CONFIGS=(
  KSU_DEBUG KSU_TOOLKIT_SUPPORT KSU_DISABLE_MANAGER KSU_DISABLE_POLICY
  KSU_MULTI_MANAGER_SUPPORT KSU_TRACEPOINT_HOOK KSU_MANUAL_HOOK
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
  local susfs="$TEMP_DIR/SuSFS" anykernel="$TEMP_DIR/AnyKernel3"

  git clone --filter=blob:none --branch "$RESUKISU_RELEASE_TAG" \
    "$RESUKISU_REPOSITORY" "$resukisu"
  RESUKISU_COMMIT=$(git -C "$resukisu" rev-parse HEAD)

  git clone --depth=1 --single-branch --branch "$SUSFS_BRANCH" \
    "$SUSFS_REPOSITORY" "$susfs"
  SUSFS_COMMIT=$(git -C "$susfs" rev-parse HEAD)

  git init -q "$anykernel"
  git -C "$anykernel" fetch --depth=1 --no-tags "$AK3_REPOSITORY" "$AK3_COMMIT"
  git -C "$anykernel" checkout --detach FETCH_HEAD
  [[ $(git -C "$anykernel" rev-parse HEAD) == "$AK3_COMMIT" ]] ||
    die "unexpected AnyKernel3 revision"

  log "ReSukiSU: $RESUKISU_RELEASE_TAG ($RESUKISU_COMMIT)"
  log "SuSFS: $SUSFS_COMMIT"
}

integrate_resukisu() {
  local common="$1/common" link="$1/common/drivers/kernelsu" marker

  ln -s ../../ReSukiSU/kernel "$link"
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$common/drivers/Makefile"
  marker=$(grep -n '^endmenu$' "$common/drivers/Kconfig" | tail -n 1 | cut -d: -f1)
  [[ -n "$marker" ]] || die "drivers/Kconfig has no endmenu marker"
  sed -i "${marker}i source \"drivers/kernelsu/Kconfig\"" "$common/drivers/Kconfig"
}

adapt_susfs_patch() {
  perl -0pi -e '
    $from = "+\t\tif (SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n+\t\t\treturn 0;";
    $to = "+\t\tif (SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n+\t\t\tgoto show_pad;";
    $count = s/\Q$from\E/$to/g;
    die "SuSFS show_smap patch changed upstream\n" unless $count == 1;
  ' "$1"
}

integrate_susfs() {
  local common="$1/common" source="$TEMP_DIR/SuSFS"
  local upstream_patch adapted_patch patch_output fuzz_file

  grep -Fq 'show_pad:' "$common/fs/proc/task_mmu.c" ||
    die "kernel does not contain the expected show_pad flow"

  upstream_patch="$source/kernel_patches/50_add_susfs_in_gki-android13-5.15.patch"
  adapted_patch="$TEMP_DIR/susfs.patch"
  [[ -f "$upstream_patch" ]] || die "SuSFS Android 13/5.15 patch is missing"
  cp -- "$upstream_patch" "$adapted_patch"
  adapt_susfs_patch "$adapted_patch"

  cp -- "$source/kernel_patches/fs/"* "$common/fs/"
  cp -- "$source/kernel_patches/include/linux/"* "$common/include/linux/"

  if ! patch_output=$(patch --verbose -d "$common" -p1 -F1 \
    --no-backup-if-mismatch < "$adapted_patch" 2>&1); then
    printf '%s\n' "$patch_output" >&2
    die "failed to apply the SuSFS kernel patch"
  fi

  fuzz_file=$(awk '
    /^[Pp]atching file / {
      file = $3
      gsub(/[\047\"]/, "", file)
    }
    /with fuzz/ { print file }
  ' <<< "$patch_output")
  if [[ $fuzz_file == fs/proc/task_mmu.c ]]; then
    log "applied SuSFS patch with fuzz 1 in fs/proc/task_mmu.c"
  elif [[ -z $fuzz_file ]]; then
    log "applied SuSFS patch without fuzz"
  else
    die "unexpected SuSFS fuzz target: $fuzz_file"
  fi

  grep -A4 -F 'SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file))' \
    "$common/fs/proc/task_mmu.c" | grep -Fq 'goto show_pad;' ||
    die "SuSFS show_pad adaptation is missing from the kernel"

  SUSFS_VERSION=$(sed -n 's/^#define SUSFS_VERSION "\([^"]*\)"/\1/p' \
    "$common/include/linux/susfs.h" | head -n 1)
  [[ $SUSFS_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "invalid SuSFS version: $SUSFS_VERSION"
}

prepare_sources() {
  local workspace=$1 common="$1/common" defconfig tool constants clang_version
  local clang_bin build_tools pahole config_out symbol

  printf '%s\n' "$SCMVERSION" > "$common/.scmversion"
  git -C "$common" apply --check "$BUILD_DIR/kabi.patch"
  git -C "$common" apply "$BUILD_DIR/kabi.patch"
  integrate_resukisu "$workspace"
  integrate_susfs "$workspace"

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
  local resukisu_short=${RESUKISU_COMMIT:0:12} susfs_short=${SUSFS_COMMIT:0:12}

  lto_label=${LTO_MODE^}
  artifact_name="$TARGET-$resukisu_short-susfs-$susfs_short"

  staging="$TEMP_DIR/package"
  mkdir -p -- "$staging/META-INF/com/google/android" "$staging/tools" "$RELEASE_DIR"
  cp -- "$anykernel/LICENSE" "$staging/"
  cp -- "$anykernel/META-INF/com/google/android/update-binary" \
    "$anykernel/META-INF/com/google/android/updater-script" \
    "$staging/META-INF/com/google/android/"
  cp -- "$anykernel/tools/ak3-core.sh" "$anykernel/tools/busybox" \
    "$anykernel/tools/magiskboot" "$staging/tools/"
  sed -e "s/@RESUKISU_VERSION@/$RESUKISU_RELEASE_TAG-$resukisu_short/" \
    -e "s/@SUSFS_VERSION@/$SUSFS_VERSION-$susfs_short/" \
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

write_action_summary() {
  [[ -n ${GITHUB_STEP_SUMMARY:-} ]] || return

  printf '%s\n' \
    '## Kernel build inputs' \
    '' \
    "- ReSukiSU: \`$RESUKISU_RELEASE_TAG\` (\`$RESUKISU_COMMIT\`)" \
    "- SuSFS: \`$SUSFS_VERSION\` (\`$SUSFS_COMMIT\`)" \
    "- ReSukiSU Manager: [upstream release]($RESUKISU_RELEASE_URL)" \
    >> "$GITHUB_STEP_SUMMARY"
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
  log "applying Droidspaces, ReSukiSU and SuSFS configuration"
  prepare_sources "$workspace"
  log "building $TARGET with ${LTO_MODE^} LTO"
  build_kernel "$workspace"
  log "packaging AnyKernel3 artifact"
  package_kernel "$workspace"
  write_action_summary
}

TEMP_DIR=$(mktemp -d -t 6sp-build.XXXXXXXX)
trap 'rm -rf -- "$TEMP_DIR"' EXIT
main "$@"
