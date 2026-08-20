#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/lib/common.sh"

aosp_root="${1:-${AOSP_WORKSPACE:-}}"
[[ -n "$aosp_root" ]] || die "usage: $0 /absolute/path/to/aosp-workspace"
assert_aosp_root "$aosp_root"

patch_lock="${PROJECT_ROOT}/locks/patches.lock.json"
[[ "$(json_value "$patch_lock" patches.0.role)" == "primary" ]] || die "primary Droidspaces patch is not locked"
patch_file="${PROJECT_ROOT}/$(json_value "$patch_lock" patches.0.path)"
expected_digest="$(json_value "$patch_lock" patches.0.sha256)"
actual_digest="$(sha256_file "$patch_file")"
[[ "$actual_digest" == "$expected_digest" ]] || die "Droidspaces patch digest mismatch: ${actual_digest}"

if git -C "${aosp_root}/common" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
  log "Droidspaces SYSVIPC kABI patch is already applied"
  exit 0
fi

git -C "${aosp_root}/common" apply --check "$patch_file"
git -C "${aosp_root}/common" apply "$patch_file"
log "applied locked Droidspaces SYSVIPC kABI patch"
