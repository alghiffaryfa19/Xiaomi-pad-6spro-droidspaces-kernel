#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/lib/common.sh"

require_command git
require_command python3

lock_file="${PROJECT_ROOT}/locks/dependencies.lock.json"
ksu_repo="$(json_value "$lock_file" dependencies.kernelsu.repository)"
ksu_commit="$(json_value "$lock_file" dependencies.kernelsu.commit)"
ak3_repo="$(json_value "$lock_file" dependencies.anykernel3.repository)"
ak3_commit="$(json_value "$lock_file" dependencies.anykernel3.commit)"

mkdir -p -- "${PROJECT_ROOT}/third_party"

checkout_dependency() {
  local name="$1"
  local repository="$2"
  local commit="$3"
  local destination="${PROJECT_ROOT}/third_party/${name}"

  if [[ -d "${destination}/.git" ]]; then
    actual="$(git -C "$destination" rev-parse HEAD)"
    [[ "$actual" == "$commit" ]] || die "${name} HEAD mismatch: ${actual}"
    assert_clean_git_tree "$destination"
    log "${name} already locked at ${commit}"
    return
  fi
  [[ ! -e "$destination" ]] || die "refusing to overwrite non-git path: ${destination}"

  temp_root="$(mktemp -d "${TMPDIR:-/tmp}/6sp-third-party.XXXXXX")"
  trap 'rm -rf -- "${temp_root}"' RETURN
  git clone --filter=blob:none --no-checkout "$repository" "${temp_root}/${name}"
  git -C "${temp_root}/${name}" checkout --detach "$commit"
  actual="$(git -C "${temp_root}/${name}" rev-parse HEAD)"
  [[ "$actual" == "$commit" ]] || die "${name} checkout mismatch: ${actual}"
  mv -- "${temp_root}/${name}" "$destination"
  trap - RETURN
  rm -rf -- "$temp_root"
  log "checked out ${name} at ${commit}"
}

checkout_dependency KernelSU "$ksu_repo" "$ksu_commit"
checkout_dependency AnyKernel3 "$ak3_repo" "$ak3_commit"

