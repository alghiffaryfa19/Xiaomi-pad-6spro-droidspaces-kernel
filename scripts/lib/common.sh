#!/usr/bin/env bash

set -Eeuo pipefail

COMMON_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${COMMON_LIB_DIR}/../.." && pwd -P)"

log() {
  printf '[6sp] %s\n' "$*"
}

die() {
  printf '[6sp] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$file" | awk '{print $1}'
  else
    die "sha256sum or shasum is required"
  fi
}

json_value() {
  local file="$1"
  local dotted_key="$2"
  python3 - "$file" "$dotted_key" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
for part in sys.argv[2].split("."):
    value = value[int(part)] if isinstance(value, list) else value[part]
print(value)
PY
}

assert_linux_x86_64() {
  [[ "$(uname -s)" == "Linux" ]] || die "kernel builds require Linux; found $(uname -s)"
  [[ "$(uname -m)" == "x86_64" ]] || die "kernel builds require Linux x86_64; found $(uname -m)"
}

assert_aosp_root() {
  local root="$1"
  [[ -d "${root}/common/.git" ]] || die "not a synced AOSP kernel workspace: ${root}"
  [[ -x "${root}/build/build.sh" ]] || die "AOSP build/build.sh is missing: ${root}"
}

assert_clean_git_tree() {
  local repo="$1"
  [[ -z "$(git -C "$repo" status --porcelain)" ]] || die "git worktree is not clean: ${repo}"
}

assert_lto_config() {
  local config_file="$1"
  local lto_mode="$2"
  [[ -f "$config_file" ]] || die "kernel config not found: ${config_file}"
  grep -Fqx 'CONFIG_LTO=y' "$config_file" || die "required setting missing: CONFIG_LTO=y"
  grep -Fqx 'CONFIG_LTO_CLANG=y' "$config_file" || die "required setting missing: CONFIG_LTO_CLANG=y"
  case "$lto_mode" in
    thin)
      grep -Fqx 'CONFIG_LTO_CLANG_THIN=y' "$config_file" || die "Thin LTO is not enabled"
      grep -Fqx '# CONFIG_LTO_CLANG_FULL is not set' "$config_file" || die "Full LTO must be disabled"
      ;;
    full)
      grep -Fqx 'CONFIG_LTO_CLANG_FULL=y' "$config_file" || die "Full LTO is not enabled"
      grep -Fqx '# CONFIG_LTO_CLANG_THIN is not set' "$config_file" || die "Thin LTO must be disabled"
      ;;
    *) die "LTO mode must be thin or full" ;;
  esac
}

assert_kernel_release() {
  local release_file="$1"
  local expected_release
  local actual_release
  [[ -f "$release_file" ]] || die "kernel release file not found: ${release_file}"
  expected_release="$(json_value "${PROJECT_ROOT}/locks/build-lock.json" kernel.uname_release)"
  actual_release="$(tr -d '\n' < "$release_file")"
  [[ "$actual_release" == "$expected_release" ]] || \
    die "kernel release mismatch: expected ${expected_release}, got ${actual_release}"
}
