#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/lib/common.sh"

config_file="${1:-}"
mode="${2:-}"
lto_mode="${3:-$(json_value "${PROJECT_ROOT}/locks/build-lock.json" kernel.lto)}"
[[ -f "$config_file" ]] || die "usage: $0 /path/to/.config [--defconfig|--final] [thin|full]"
[[ "$mode" == "" || "$mode" == "--defconfig" || "$mode" == "--final" ]] || die "mode must be --defconfig or --final"

required_y=(
  SYSVIPC POSIX_MQUEUE IPC_NS PID_NS DEVTMPFS
  NETFILTER_XT_MATCH_ADDRTYPE USER_NS
  IP_NF_TARGET_REJECT NETFILTER_XT_TARGET_LOG NETFILTER_XT_MATCH_RECENT
  IP_SET IP_SET_HASH_IP IP_SET_HASH_NET NETFILTER_XT_SET
  TMPFS_POSIX_ACL TMPFS_XATTR KSU
)
required_n=(KSU_DEBUG KSU_DISABLE_MANAGER KSU_DISABLE_POLICY)

if [[ "$mode" != "--defconfig" ]]; then
  required_y+=(MODVERSIONS TRIM_UNUSED_KSYMS KPROBES EXT4_FS)
  assert_lto_config "$config_file" "$lto_mode"
fi

for symbol in "${required_y[@]}"; do
  grep -Fqx "CONFIG_${symbol}=y" "$config_file" || die "required setting missing: CONFIG_${symbol}=y"
done
for symbol in "${required_n[@]}"; do
  grep -Fqx "# CONFIG_${symbol} is not set" "$config_file" || die "required disabled setting missing: CONFIG_${symbol}"
done

if grep -Eq '^CONFIG_(KSU_SUSFS|SUSFS|NT_SYNC|NTSYNC)=y$' "$config_file"; then
  die "excluded feature enabled in config"
fi

log "config verification passed: ${config_file}"
