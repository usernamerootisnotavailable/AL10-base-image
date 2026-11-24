#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_versions
load_build_env
cd "$REPO_ROOT"

require_var IMAGE_FILE
[[ -f "$IMAGE_FILE" ]] || die "image does not exist: $IMAGE_FILE"
need_cmd python3

mkdir -p "$DIST_DIR"

export DIST_DIR IMAGE_FILE IMAGE_VERSION IMAGE_BASENAME ALMA_CLOUD_FS
export ALMA_RELEASE ALMA_IMAGE_DATE ALMA_CLOUD_IMAGE_URL ALMA_CLOUD_IMAGE_SHA256
export BUILD_DATE BUILD_GIT_SHA

python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path

dist = Path(os.environ["DIST_DIR"])
image = Path(os.environ["IMAGE_FILE"])
package_list = dist / "package-list.txt"
image_info = dist / "image-info.txt"

def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

manifest = {
    "name": "al10-base",
    "version": os.environ["IMAGE_VERSION"],
    "artifact": image.name,
    "artifact_sha256": sha256(image),
    "artifact_size_bytes": image.stat().st_size,
    "architecture": "x86_64",
    "almalinux_release": os.environ["ALMA_RELEASE"],
    "base_image_release_date": os.environ["ALMA_IMAGE_DATE"],
    "base_image_url": os.environ["ALMA_CLOUD_IMAGE_URL"],
    "base_image_sha256": os.environ["ALMA_CLOUD_IMAGE_SHA256"],
    "root_filesystem": os.environ["ALMA_CLOUD_FS"],
    "build_date": os.environ["BUILD_DATE"],
    "git_sha": os.environ["BUILD_GIT_SHA"],
    "package_list": package_list.name if package_list.exists() else None,
    "image_info": image_info.name if image_info.exists() else None,
}

(dist / "build-manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY

log "Wrote $DIST_DIR/build-manifest.json"
