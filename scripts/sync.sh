#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/lib/common.sh"

assert_linux_x86_64
require_command repo
require_command git
require_command python3

workspace="${AOSP_WORKSPACE:-}"
[[ -n "$workspace" ]] || die "set AOSP_WORKSPACE to an absolute path on the VM's native Linux filesystem"
[[ "$workspace" == /* ]] || die "AOSP_WORKSPACE must be absolute: ${workspace}"

mkdir -p -- "$workspace"
fs_type="$(stat -f -c %T "$workspace")"
case "$fs_type" in
  fuse*|9p|virtiofs) die "refusing to sync onto shared filesystem type ${fs_type}: ${workspace}" ;;
esac

manifest_commit="$(json_value "${PROJECT_ROOT}/locks/build-lock.json" kernel.manifest_commit)"
manifest_name="OS3.0.304.0-pinned.xml"

log "initializing manifest repository at ${manifest_commit}"
(
  cd -- "$workspace"
  repo init \
    -u https://android.googlesource.com/kernel/manifest \
    -b "$manifest_commit" \
    --no-clone-bundle \
    --no-tags
)

install -m 0644 "${PROJECT_ROOT}/manifests/${manifest_name}" "${workspace}/.repo/manifests/${manifest_name}"
(
  cd -- "$workspace"
  repo init -m "$manifest_name"
)

jobs="${SYNC_JOBS:-8}"
log "syncing exact revisions with ${jobs} jobs"
(
  cd -- "$workspace"
  repo sync --current-branch --no-clone-bundle --no-tags --fail-fast -j "$jobs"
)

actual_common="$(git -C "${workspace}/common" rev-parse HEAD)"
expected_common="$(json_value "${PROJECT_ROOT}/locks/build-lock.json" kernel.common_commit)"
[[ "$actual_common" == "$expected_common" ]] || die "common mismatch: ${actual_common}"

"${SCRIPT_DIR}/verify-source.sh" "$workspace"

mkdir -p -- "${workspace}/.6sp-metadata"
(
  cd -- "$workspace"
  repo manifest -r -o "${workspace}/.6sp-metadata/actual-manifest.xml"
)
log "source sync complete: ${workspace}"
