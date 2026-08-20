#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/lib/common.sh"

assert_linux_x86_64
require_command zip
require_command unzip

aosp_root="${1:-${AOSP_WORKSPACE:-}}"
[[ -n "$aosp_root" ]] || die "usage: $0 /absolute/path/to/aosp-workspace"
assert_aosp_root "$aosp_root"

target="$(json_value "${PROJECT_ROOT}/locks/build-lock.json" target)"
expected_ak3="$(json_value "${PROJECT_ROOT}/locks/dependencies.lock.json" dependencies.anykernel3.commit)"
ak3="${PROJECT_ROOT}/third_party/AnyKernel3"
out_root="${OUT_ROOT:-${aosp_root}/out-6sp}"
dist_dir="${out_root}/dist-custom"
image="${dist_dir}/Image"

[[ -d "${ak3}/.git" ]] || die "AnyKernel3 is not fetched"
[[ "$(git -C "$ak3" rev-parse HEAD)" == "$expected_ak3" ]] || die "AnyKernel3 commit mismatch"
assert_clean_git_tree "$ak3"
[[ -f "$image" ]] || die "custom Image not found: ${image}"
assert_lto_config "${out_root}/custom/common/.config" \
  "$(json_value "${PROJECT_ROOT}/locks/build-lock.json" kernel.lto)"
assert_kernel_release "${out_root}/custom/common/include/config/kernel.release"

release_dir="${RELEASE_DIR:-${PROJECT_ROOT}/releases}"
archive="${release_dir}/${target}-anykernel3.zip"
checksum="${release_dir}/${target}-SHA256SUMS.txt"
staging="$(mktemp -d "${TMPDIR:-/tmp}/6sp-anykernel.XXXXXX")"
cleanup() {
  rm -rf -- "$staging"
}
trap cleanup EXIT

mkdir -p -- "$release_dir"
cp -a -- "${ak3}/." "$staging/"
rm -rf -- "${staging}/.git" "${staging}/.github" "${staging}/modules"
rm -f -- "${staging}/README.md" "${staging}/patch/placeholder" "${staging}/ramdisk/placeholder"
install -m 0644 -- "${PROJECT_ROOT}/packaging/anykernel.sh" "${staging}/anykernel.sh"
printf '%s\n' "$target" > "${staging}/version"
chmod 0644 -- "${staging}/version"
install -m 0644 -- "$image" "${staging}/Image"

# Normalize timestamps and ordering so identical inputs produce identical zips.
find "$staging" -exec touch -h -d '@315532800' -- {} +
archive_tmp="${release_dir}/.${target}-anykernel3.zip.tmp"
rm -f -- "$archive_tmp"
(
  cd -- "$staging"
  find . -type f -printf '%P\n' | LC_ALL=C sort | zip -q -X -9 "$archive_tmp" -@
)
mv -f -- "$archive_tmp" "$archive"

entries="$(unzip -Z1 "$archive")"
for required in Image LICENSE anykernel.sh META-INF/com/google/android/update-binary tools/ak3-core.sh version; do
  grep -Fqx "$required" <<<"${entries#./}" || die "AnyKernel3 archive missing: ${required}"
done
if grep -Eq '(^|/)(\.git|README\.md|placeholder)(/|$)' <<<"$entries"; then
  die "AnyKernel3 archive contains development-only files"
fi
archive_digest="$(sha256_file "$archive")"
printf '%s  %s\n' "$archive_digest" "$(basename "$archive")" > "$checksum"
log "AnyKernel3 package complete: ${archive}"
log "SHA-256: ${archive_digest}"
