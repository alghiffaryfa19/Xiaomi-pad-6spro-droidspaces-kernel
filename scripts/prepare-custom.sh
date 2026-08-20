#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/lib/common.sh"

aosp_root="${1:-${AOSP_WORKSPACE:-}}"
[[ -n "$aosp_root" ]] || die "usage: $0 /absolute/path/to/aosp-workspace"
assert_aosp_root "$aosp_root"

expected_common="$(json_value "${PROJECT_ROOT}/locks/build-lock.json" kernel.common_commit)"
actual_common="$(git -C "${aosp_root}/common" rev-parse HEAD)"
[[ "$actual_common" == "$expected_common" ]] || die "common HEAD mismatch: ${actual_common}"

expected_scmversion="$(json_value "${PROJECT_ROOT}/locks/build-lock.json" kernel.scmversion)"
actual_scmversion="$(tr -d '\n' < "${PROJECT_ROOT}/configs/scmversion")"
[[ "$actual_scmversion" == "$expected_scmversion" ]] || die "pinned scmversion mismatch"
install -m 0644 -- "${PROJECT_ROOT}/configs/scmversion" "${aosp_root}/common/.scmversion"

"${SCRIPT_DIR}/apply-droidspaces.sh" "$aosp_root"
"${SCRIPT_DIR}/integrate-kernelsu.sh" "$aosp_root"
"${SCRIPT_DIR}/apply-config.sh" "$aosp_root"
log "custom source preparation complete"
