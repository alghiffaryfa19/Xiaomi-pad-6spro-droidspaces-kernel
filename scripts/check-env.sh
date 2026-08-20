#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/lib/common.sh"

assert_linux_x86_64

required=(git curl python3 repo rsync zip unzip make perl file bc bison flex openssl)
missing=()
for command_name in "${required[@]}"; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    missing+=("$command_name")
  fi
done

if ((${#missing[@]})); then
  die "missing host tools: ${missing[*]}"
fi

mem_kib="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
((mem_kib >= 23000000)) || die "at least about 24 GiB assigned RAM is required; MemTotal=${mem_kib} KiB"

check_path="${AOSP_WORKSPACE:-$PWD}"
mkdir -p -- "$check_path"
free_kib="$(df -Pk "$check_path" | awk 'NR == 2 {print $4}')"
((free_kib >= 167772160)) || die "at least 160 GiB free is required at ${check_path}; free=${free_kib} KiB"

case "$(stat -f -c %T "$check_path")" in
  fuse*|9p|virtiofs)
    die "${check_path} appears to be a shared filesystem; use the VM's native Linux filesystem"
    ;;
esac

log "host OK: $(uname -srmo)"
log "memory OK: ${mem_kib} KiB"
log "disk OK: ${free_kib} KiB free at ${check_path}"
log "environment check passed"

