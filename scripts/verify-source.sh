#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/lib/common.sh"

aosp_root="${1:-${AOSP_WORKSPACE:-}}"
[[ -n "$aosp_root" ]] || die "usage: $0 /absolute/path/to/aosp-workspace"
assert_aosp_root "$aosp_root"

python3 - "${PROJECT_ROOT}/manifests/OS3.0.304.0-pinned.xml" "$aosp_root" <<'PY'
import pathlib
import subprocess
import sys
import xml.etree.ElementTree as ET

manifest = ET.parse(sys.argv[1])
root = pathlib.Path(sys.argv[2])
failures = []
for project in manifest.findall("project"):
    path = project.attrib["path"]
    expected = project.attrib["revision"]
    checkout = root / path
    try:
        actual = subprocess.check_output(
            ["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        failures.append(f"missing checkout: {path}")
        continue
    if actual != expected:
        failures.append(f"{path}: expected {expected}, got {actual}")
if failures:
    raise SystemExit("source lock verification failed:\n" + "\n".join(failures))
print(f"source lock OK: {len(manifest.findall('project'))} projects")
PY

