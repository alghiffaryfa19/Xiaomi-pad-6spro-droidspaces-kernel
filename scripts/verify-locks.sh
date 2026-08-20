#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/lib/common.sh"

require_command python3
require_command git

python3 - "${PROJECT_ROOT}" <<'PY'
import json
import pathlib
import re
import sys
import xml.etree.ElementTree as ET

root = pathlib.Path(sys.argv[1])
for path in sorted((root / "locks").glob("*.json")):
    json.loads(path.read_text(encoding="utf-8"))

manifest = root / "manifests" / "OS3.0.304.0-pinned.xml"
tree = ET.parse(manifest)
projects = tree.findall("project")
if len(projects) != 19:
    raise SystemExit(f"expected 19 pinned projects, found {len(projects)}")
for project in projects:
    revision = project.get("revision", "")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise SystemExit(f"floating or invalid revision for {project.get('name')}: {revision}")
print(f"manifest OK: {len(projects)} exact projects")
PY

python3 - "${PROJECT_ROOT}" <<'PY'
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
lock = json.loads((root / "locks" / "patches.lock.json").read_text(encoding="utf-8"))
for item in lock["patches"]:
    path = root / item["path"]
    if not path.is_file():
        raise SystemExit(f"missing patch: {path}")
    try:
        actual = subprocess.check_output(["sha256sum", str(path)], text=True).split()[0]
    except FileNotFoundError:
        actual = subprocess.check_output(["shasum", "-a", "256", str(path)], text=True).split()[0]
    if actual != item["sha256"]:
        raise SystemExit(f"patch digest mismatch: {path}\nexpected {item['sha256']}\nactual   {actual}")
    print(f"patch OK: {path.name} {actual}")
PY

dependency_lock="${PROJECT_ROOT}/locks/dependencies.lock.json"
for name in KernelSU AnyKernel3; do
  checkout="${PROJECT_ROOT}/third_party/${name}"
  if [[ ! -d "${checkout}/.git" ]]; then
    log "${name} not fetched yet; commit verification deferred"
    continue
  fi
  case "$name" in
    KernelSU) expected="$(json_value "$dependency_lock" dependencies.kernelsu.commit)" ;;
    AnyKernel3) expected="$(json_value "$dependency_lock" dependencies.anykernel3.commit)" ;;
  esac
  actual="$(git -C "$checkout" rev-parse HEAD)"
  [[ "$actual" == "$expected" ]] || die "${name} commit mismatch: ${actual}"
  assert_clean_git_tree "$checkout"
  log "dependency OK: ${name} ${actual}"
done

log "all available locks verified"

