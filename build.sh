#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
BUILD_DIR="$ROOT/build"
BUILD_CONFIG_FILE="$BUILD_DIR/config.env"
MANIFEST="$BUILD_DIR/manifest.xml"
CACHE_DIR="${CACHE_DIR:-$ROOT/.cache}"
TEMP_DIRS=()

log() { printf '[6sp] %s\n' "$*"; }
die() { printf '[6sp] ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
  local path
  set +u
  for path in "${TEMP_DIRS[@]}"; do
    [[ -d "$path" ]] && rm -rf -- "$path"
  done
}
trap cleanup EXIT

make_temp() {
  local name=$1 path
  path=$(mktemp -d -t 6sp-build.XXXXXXXX)
  TEMP_DIRS+=("$path")
  printf -v "$name" '%s' "$path"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing host tool: $1"
}

load_config() {
  local commit
  [[ -f "$BUILD_CONFIG_FILE" ]] || die "build configuration not found: $BUILD_CONFIG_FILE"
  # shellcheck source=build/config.env
  source "$BUILD_CONFIG_FILE"
  [[ -n "$TARGET" && -n "$MANIFEST_COMMIT" && -n "$COMMON_COMMIT" && -n "$SCMVERSION" &&
     -n "$KERNEL_RELEASE" && -n "$AOSP_BUILD_CONFIG" && -n "$LTO_MODE" && -n "$ROOT_SOLUTION" &&
     -n "$ROOT_SOLUTION_REPOSITORY" && -n "$ROOT_SOLUTION_COMMIT" && -n "$AK3_REPOSITORY" &&
     -n "$AK3_COMMIT" && -n "$PATCH_FILE" &&
     -n "$PATCH_SHA256" ]] || die 'required lock value is missing'
  for commit in "$MANIFEST_COMMIT" "$COMMON_COMMIT" "$ROOT_SOLUTION_COMMIT" "$AK3_COMMIT"; do
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "invalid pinned commit: $commit"
  done
  [[ "$PATCH_SHA256" =~ ^[0-9a-f]{64}$ ]] || die 'invalid patch digest'
}

absolute_path() {
  realpath -m -- "$1"
}

workspace() {
  local value=${1:-${AOSP_WORKSPACE:-}}
  [[ -n "$value" ]] || die 'pass an AOSP workspace path or set AOSP_WORKSPACE'
  absolute_path "$value"
}

require_workspace() {
  [[ -d "$1/common/.git" && -f "$1/build/build.sh" ]] ||
    die "not a synced AOSP kernel workspace: $1"
}

git_head() {
  git -C "$1" rev-parse HEAD
}

require_clean() {
  [[ -z "$(git -C "$1" status --porcelain)" ]] || die "git worktree is not clean: $1"
}

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

manifest_projects() {
  sed -n '/<project /p' "$MANIFEST"
}

project_attribute() {
  sed -n "s/.* $2=\"\([^\"]*\)\".*/\1/p" <<<"$1"
}

verify_inputs() {
  local line revision name checkout patch="$BUILD_DIR/$PATCH_FILE" input
  for input in "$BUILD_CONFIG_FILE" "$MANIFEST" "$patch" "$BUILD_DIR/scmversion" \
    "$BUILD_DIR/droidspaces.fragment" "$BUILD_DIR/resukisu.fragment" \
    "$BUILD_DIR/release.fragment" "$BUILD_DIR/anykernel.sh"; do
    [[ -s "$input" ]] || die "build input is missing or empty: $input"
  done

  while IFS= read -r line; do
    revision=$(project_attribute "$line" revision)
    name=$(project_attribute "$line" name)
    [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die "invalid revision for $name: $revision"
  done < <(manifest_projects)

  [[ "$(hash_file "$patch")" == "$PATCH_SHA256" ]] ||
    die "patch digest mismatch: $patch"

  for name in "$ROOT_SOLUTION" AnyKernel3; do
    checkout="$CACHE_DIR/$name"
    [[ -e "$checkout" ]] || continue
    [[ -d "$checkout/.git" ]] || die "$name checkout is not a git repository"
    if [[ "$name" == "$ROOT_SOLUTION" ]]; then
      [[ "$(git_head "$checkout")" == "$ROOT_SOLUTION_COMMIT" ]] || die "$ROOT_SOLUTION checkout does not match its lock"
    else
      [[ "$(git_head "$checkout")" == "$AK3_COMMIT" ]] || die 'AnyKernel3 checkout does not match its lock'
    fi
    require_clean "$checkout"
  done
  log 'build inputs verified'
}

verify_sources() {
  local root=$1 line path revision checkout failures=()
  require_workspace "$root"
  while IFS= read -r line; do
    path=$(project_attribute "$line" path)
    revision=$(project_attribute "$line" revision)
    checkout="$root/$path"
    if [[ ! -e "$checkout/.git" ]]; then
      failures+=("missing: $path")
    elif [[ "$(git_head "$checkout")" != "$revision" ]]; then
      failures+=("revision mismatch: $path")
    fi
  done < <(manifest_projects)
  ((${#failures[@]} == 0)) || die $'source lock verification failed:\n'"$(printf '%s\n' "${failures[@]}")"
  log 'source lock verified'
}

check_host() {
  local root=${1:-$PWD} tool memory min_memory min_disk free fs
  [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] ||
    die "kernel builds require Linux x86_64, found $(uname -s) $(uname -m)"
  for tool in git repo rsync zip unzip make perl file bc bison flex openssl realpath; do
    require_command "$tool"
  done

  min_memory=${MIN_MEMORY_KIB:-8388608}
  min_disk=${MIN_DISK_KIB:-13631488}
  [[ "$min_memory" =~ ^[1-9][0-9]*$ && "$min_disk" =~ ^[1-9][0-9]*$ ]] ||
    die 'MIN_MEMORY_KIB and MIN_DISK_KIB must be positive integers'
  mkdir -p -- "$root"
  memory=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  free=$(df -Pk -- "$root" | awk 'NR == 2 {print $4}')
  ((memory >= min_memory)) || die "need $min_memory KiB RAM, found $memory KiB"
  ((free >= min_disk)) || die "need $min_disk KiB free at $root, found $free KiB"
  fs=$(stat -f -c %T -- "$root")
  [[ "$fs" != fuse* && "$fs" != 9p* && "$fs" != virtiofs* ]] ||
    die "use a native Linux filesystem instead of $fs: $root"
  log "host verified: $memory KiB RAM, $free KiB free"
}

sync_sources() {
  local root=$1 metadata
  check_host "$root"
  (cd "$root" && repo init --depth=1 -u https://android.googlesource.com/kernel/manifest \
    -b "$MANIFEST_COMMIT" --no-clone-bundle --no-tags)
  cp -- "$MANIFEST" "$root/.repo/manifests/$(basename "$MANIFEST")"
  (cd "$root" && repo init --depth=1 -m "$(basename "$MANIFEST")" --no-clone-bundle --no-tags)
  (cd "$root" && repo sync --current-branch --no-clone-bundle --no-tags --fail-fast \
    -j "${SYNC_JOBS:-8}")
  verify_sources "$root"
  metadata="$root/.6sp-metadata"
  mkdir -p -- "$metadata"
  (cd "$root" && repo manifest -r -o "$metadata/actual-manifest.xml")
}

fetch_dependency() {
  local name=$1 repository=$2 commit=$3 destination="$CACHE_DIR/$1" temporary checkout
  if [[ -e "$destination" ]]; then
    [[ -d "$destination/.git" && "$(git_head "$destination")" == "$commit" ]] ||
      die "refusing to replace unexpected path: $destination"
    require_clean "$destination"
    log "$name already available"
    return
  fi
  make_temp temporary
  checkout="$temporary/$name"
  git clone --filter=blob:none --no-checkout "$repository" "$checkout"
  git -C "$checkout" checkout --detach "$commit"
  [[ "$(git_head "$checkout")" == "$commit" ]] || die "$name checkout mismatch"
  mkdir -p -- "$CACHE_DIR"
  mv -- "$checkout" "$destination"
}

fetch_dependencies() {
  fetch_dependency "$ROOT_SOLUTION" "$ROOT_SOLUTION_REPOSITORY" "$ROOT_SOLUTION_COMMIT"
  fetch_dependency AnyKernel3 "$AK3_REPOSITORY" "$AK3_COMMIT"
}

apply_config_fragment() {
  local tool=$1 defconfig=$2 fragment=$3 line symbol
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    [[ -n "$line" ]] || continue
    if [[ "$line" == 'CONFIG_'*'=y' ]]; then
      symbol=${line#CONFIG_}
      "$tool" --file "$defconfig" -e "${symbol%=y}"
    elif [[ "$line" == '# CONFIG_'*' is not set' ]]; then
      symbol=${line#\# CONFIG_}
      "$tool" --file "$defconfig" -d "${symbol% is not set}"
    elif [[ "$line" != '#'* ]]; then
      die "unsupported config line in $fragment: $line"
    fi
  done < "$fragment"
}

require_config_line() {
  grep -Fqx -- "$2" "$1" || die "config verification failed; missing: $2"
}

verify_config() {
  local config=$1 final=${2:-false} symbol lto other
  [[ -f "$config" ]] || die "kernel config not found: $config"
  for symbol in SYSVIPC POSIX_MQUEUE IPC_NS PID_NS DEVTMPFS NETFILTER_XT_MATCH_ADDRTYPE \
    USER_NS IP_NF_TARGET_REJECT NETFILTER_XT_TARGET_LOG NETFILTER_XT_MATCH_RECENT \
    IP_SET IP_SET_HASH_IP IP_SET_HASH_NET NETFILTER_XT_SET TMPFS_POSIX_ACL TMPFS_XATTR KSU \
    KSU_MULTI_MANAGER_SUPPORT KSU_TRACEPOINT_HOOK; do
    require_config_line "$config" "CONFIG_$symbol=y"
  done
  for symbol in KSU_DEBUG KSU_TOOLKIT_SUPPORT KSU_DISABLE_MANAGER KSU_DISABLE_POLICY; do
    require_config_line "$config" "# CONFIG_$symbol is not set"
  done
  grep -Eq '^CONFIG_(KSU_SUSFS|SUSFS|NT_SYNC|NTSYNC)=y$' "$config" &&
    die 'excluded feature enabled in kernel config'

  if [[ "$final" == true ]]; then
    for symbol in MODVERSIONS TRIM_UNUSED_KSYMS KPROBES EXT4_FS; do
      require_config_line "$config" "CONFIG_$symbol=y"
    done
    lto=$(tr '[:lower:]' '[:upper:]' <<<"$LTO_MODE")
    [[ "$lto" == THIN ]] && other=FULL || other=THIN
    require_config_line "$config" 'CONFIG_LTO=y'
    require_config_line "$config" 'CONFIG_LTO_CLANG=y'
    require_config_line "$config" "CONFIG_LTO_CLANG_$lto=y"
    require_config_line "$config" "# CONFIG_LTO_CLANG_$other is not set"
  fi
  log "config verified: $config"
}

prepare_sources() {
  local root=$1 common="$1/common" patch="$BUILD_DIR/$PATCH_FILE" root_source root_solution link
  local makefile kconfig marker tool defconfig constants clang_version clang_bin config_tmp
  require_workspace "$root"
  [[ "$(git_head "$common")" == "$COMMON_COMMIT" ]] || die 'common checkout does not match the build lock'
  [[ "$(tr -d '\r\n' < "$BUILD_DIR/scmversion")" == "$SCMVERSION" ]] ||
    die 'scmversion does not match the pinned configuration'
  cp -- "$BUILD_DIR/scmversion" "$common/.scmversion"

  if git -C "$common" apply --reverse --check "$patch" >/dev/null 2>&1; then
    log 'Droidspaces kABI patch already applied'
  else
    git -C "$common" apply --check "$patch"
    git -C "$common" apply "$patch"
  fi

  root_source="$CACHE_DIR/$ROOT_SOLUTION"
  root_solution="$root/$ROOT_SOLUTION"
  [[ -d "$root_source/.git" && "$(git_head "$root_source")" == "$ROOT_SOLUTION_COMMIT" ]] ||
    die "locked $ROOT_SOLUTION dependency is unavailable"
  require_clean "$root_source"
  if [[ ! -e "$root_solution" ]]; then
    git clone --no-hardlinks "$root_source" "$root_solution"
    git -C "$root_solution" checkout --detach "$ROOT_SOLUTION_COMMIT"
  fi
  [[ -d "$root_solution/.git" && "$(git_head "$root_solution")" == "$ROOT_SOLUTION_COMMIT" ]] ||
    die "workspace $ROOT_SOLUTION checkout mismatch"
  require_clean "$root_solution"

  link="$common/drivers/kernelsu"
  if [[ -L "$link" ]]; then
    [[ $(readlink "$link") == "../../$ROOT_SOLUTION/kernel" ]] ||
      die 'unexpected drivers/kernelsu symlink'
  elif [[ -e "$link" ]]; then
    die 'drivers/kernelsu exists and is not a symlink'
  else
    ln -s "../../$ROOT_SOLUTION/kernel" "$link"
  fi

  makefile="$common/drivers/Makefile"
  grep -Fqx 'obj-$(CONFIG_KSU) += kernelsu/' "$makefile" ||
    printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$makefile"
  kconfig="$common/drivers/Kconfig"
  if ! grep -Fqx 'source "drivers/kernelsu/Kconfig"' "$kconfig"; then
    marker=$(grep -n '^endmenu$' "$kconfig" | tail -n 1 | cut -d: -f1)
    [[ -n "$marker" ]] || die 'drivers/Kconfig has no endmenu marker'
    sed -i "${marker}i source \"drivers/kernelsu/Kconfig\"" "$kconfig"
  fi

  tool="$common/scripts/config"
  defconfig="$common/arch/arm64/configs/gki_defconfig"
  [[ -x "$tool" && -f "$defconfig" ]] || die 'kernel config tools are unavailable'
  apply_config_fragment "$tool" "$defconfig" "$BUILD_DIR/droidspaces.fragment"
  apply_config_fragment "$tool" "$defconfig" "$BUILD_DIR/resukisu.fragment"

  constants="$common/build.config.constants"
  clang_version=$(sed -n 's/^CLANG_VERSION=//p' "$constants" | head -n 1)
  clang_bin="$root/prebuilts/clang/host/linux-x86/clang-$clang_version/bin"
  [[ -x "$clang_bin/clang" ]] || die "pinned clang is unavailable: $clang_bin"
  make_temp config_tmp
  PATH="$clang_bin:$PATH" make -s -C "$common" O="$config_tmp" ARCH=arm64 LLVM=1 gki_defconfig
  PATH="$clang_bin:$PATH" make -s -C "$common" O="$config_tmp" ARCH=arm64 LLVM=1 savedefconfig
  cp -- "$config_tmp/defconfig" "$defconfig"
  PATH="$clang_bin:$PATH" make -s -C "$common" O="$config_tmp" ARCH=arm64 LLVM=1 gki_defconfig
  verify_config "$config_tmp/.config" false
  log 'source preparation complete'
}

output_root() {
  local root=$1
  absolute_path "${OUT_ROOT:-$root/out-6sp}"
}

verify_release() {
  [[ -f "$1" ]] || die "kernel release file not found: $1"
  [[ "$(tr -d '\r\n' < "$1")" == "$KERNEL_RELEASE" ]] ||
    die 'kernel release does not match the pinned configuration'
}

build_kernel() {
  local root=$1 out build_out dist artifact
  verify_sources "$root"
  [[ -d "$root/$ROOT_SOLUTION/.git" && "$(git_head "$root/$ROOT_SOLUTION")" == "$ROOT_SOLUTION_COMMIT" ]] ||
    die "$ROOT_SOLUTION has not been prepared"
  git -C "$root/common" apply --reverse --check "$BUILD_DIR/$PATCH_FILE" >/dev/null 2>&1 ||
    die 'Droidspaces patch has not been applied'

  out=$(output_root "$root")
  build_out="$out/custom"
  dist="$out/dist-custom"
  mkdir -p -- "$build_out" "$dist"
  (
    cd "$root"
    LTO="$LTO_MODE" BUILD_CONFIG="$AOSP_BUILD_CONFIG" \
      GKI_BUILD_CONFIG_FRAGMENT="$BUILD_DIR/release.fragment" \
      OUT_DIR="$build_out" DIST_DIR="$dist" ./build/build.sh
  )
  [[ -f "$dist/Image" ]] || die 'custom Image was not produced'
  verify_config "$build_out/common/.config" true
  verify_release "$build_out/common/include/config/kernel.release"
  while IFS= read -r -d '' artifact; do
    [[ $(basename "$artifact") == Image ]] || rm -rf -- "$artifact"
  done < <(find "$dist" -mindepth 1 -maxdepth 1 -print0)
  log "kernel build complete: $dist/Image"
}

package_kernel() {
  local root=$1 out image ak3 release archive checksum staging temporary_archive digest
  out=$(output_root "$root")
  image="$out/dist-custom/Image"
  verify_config "$out/custom/common/.config" true
  verify_release "$out/custom/common/include/config/kernel.release"
  [[ -f "$image" ]] || die "custom Image not found: $image"

  ak3="$CACHE_DIR/AnyKernel3"
  [[ -d "$ak3/.git" && "$(git_head "$ak3")" == "$AK3_COMMIT" ]] ||
    die 'locked AnyKernel3 dependency is unavailable'
  require_clean "$ak3"

  release=$(absolute_path "${RELEASE_DIR:-$ROOT/releases}")
  mkdir -p -- "$release"
  archive="$release/$TARGET-anykernel3.zip"
  checksum="$release/$TARGET-SHA256SUMS.txt"
  make_temp staging
  mkdir -p -- "$staging/META-INF/com/google/android" "$staging/tools"
  cp -- "$ak3/LICENSE" "$staging/"
  cp -- "$ak3/META-INF/com/google/android/update-binary" \
    "$ak3/META-INF/com/google/android/updater-script" "$staging/META-INF/com/google/android/"
  cp -- "$ak3/tools/ak3-core.sh" "$ak3/tools/busybox" "$ak3/tools/magiskboot" "$staging/tools/"
  cp -- "$BUILD_DIR/anykernel.sh" "$staging/anykernel.sh"
  cp -- "$image" "$staging/Image"
  printf '%s\n' "$TARGET" > "$staging/version"

  temporary_archive="$release/.$TARGET-anykernel3.tmp.zip"
  rm -f -- "$temporary_archive"
  (cd "$staging" && find . -type f -printf '%P\n' | zip -q -9 "$temporary_archive" -@)
  mv -f -- "$temporary_archive" "$archive"

  unzip -tq "$archive" >/dev/null
  digest=$(hash_file "$archive")
  printf '%s  %s\n' "$digest" "$(basename "$archive")" > "$checksum"
  log "package complete: $archive"
  log "SHA-256: $digest"
}

usage() {
  cat >&2 <<'EOF'
usage: build.sh COMMAND [AOSP_WORKSPACE]

commands:
  check      validate the Linux build host
  verify     validate pinned build inputs and local dependencies
  sync       shallow-sync the pinned AOSP source
  deps       fetch pinned ReSukiSU and AnyKernel3 checkouts
  prepare    apply the patch, ReSukiSU and recommended config
  build      build and verify the custom kernel
  package    create and verify the AnyKernel3 archive
  release    check, verify, deps, prepare, build and package
EOF
  exit 2
}

main() {
  (($# >= 1 && $# <= 2)) || usage
  local command=$1 argument=${2:-} root=''
  case "$command" in
    check|verify|sync|deps|prepare|build|package|release) ;;
    *) usage ;;
  esac
  load_config
  if [[ "$command" != verify && "$command" != deps ]]; then
    if [[ "$command" == check && -z "$argument" && -z "${AOSP_WORKSPACE:-}" ]]; then
      root=''
    else
      root=$(workspace "$argument")
    fi
  fi

  case "$command" in
    check) check_host "${root:-$PWD}" ;;
    verify) verify_inputs ;;
    sync) sync_sources "$root" ;;
    deps) verify_inputs; fetch_dependencies ;;
    prepare) verify_inputs; prepare_sources "$root" ;;
    build) build_kernel "$root" ;;
    package) package_kernel "$root" ;;
    release)
      check_host "$root"
      verify_inputs
      fetch_dependencies
      prepare_sources "$root"
      build_kernel "$root"
      package_kernel "$root"
      ;;
  esac
}

main "$@"
