#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_versions
cd "$REPO_ROOT"

BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BUILD_GIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
export BUILD_DATE BUILD_GIT_SHA

PACKER_BIN="${PACKER_BIN:-packer}"
need_cmd "$PACKER_BIN"
need_cmd qemu-img
need_cmd ssh-keygen
need_cmd curl
need_cmd sha256sum
need_cmd python3

require_var ALMA_CLOUD_IMAGE_URL
require_var ALMA_CLOUD_IMAGE_SHA256
require_var IMAGE_VERSION

on_error() {
  local status=$?
  printf 'ERROR: command failed with status %s at line %s: %s\n' \
    "$status" "$LINENO" "$BASH_COMMAND" >&2
}
trap on_error ERR

mkdir -p "$BUILD_DIR/base" "$BUILD_DIR/ssh" "$DIST_DIR"
# Packer requires its output directory not to exist. It creates the directory
# itself after validation, so never pre-create either path here.
rm -rf "$BUILD_DIR/packer-output" "$BUILD_DIR/validate-output"
rm -f "$BUILD_DIR/console.log"

qemu_accel

{
  log "Build directory disk usage"
  df -h "$BUILD_DIR" || true
  log "Resource limits"
  ulimit -a || true
  log "Memory"
  free -h || true
} >&2

base_image="$BUILD_DIR/base/${ALMA_CLOUD_IMAGE_NAME}"

if [[ -n "${BASE_IMAGE_FILE:-}" ]]; then
  base_image="$(absolute_path "$BASE_IMAGE_FILE")"
  log "Using local base image: $base_image"
elif [[ -f "$base_image" && "$(sha256_file "$base_image")" == "$ALMA_CLOUD_IMAGE_SHA256" ]]; then
  log "Using cached base image: $base_image"
else
  read -r -a image_urls <<<"${ALMA_CLOUD_IMAGE_URL} ${ALMA_CLOUD_IMAGE_URL_FALLBACKS:-}"
  downloaded=0
  for url in "${image_urls[@]}"; do
    log "Downloading pinned base image from $url"
    if curl \
      --fail \
      --location \
      --no-progress-meter \
      --show-error \
      --verbose \
      --http1.1 \
      --retry 3 \
      --retry-all-errors \
      --retry-delay 5 \
      --connect-timeout 30 \
      --max-time 900 \
      --output "${base_image}.part" \
      --write-out 'HTTP %{http_code}, downloaded %{size_download} bytes\n' \
      "$url"; then
      if [[ "$(sha256_file "${base_image}.part")" == "$ALMA_CLOUD_IMAGE_SHA256" ]]; then
        log "base image checksum verified"
        mv "${base_image}.part" "$base_image"
        downloaded=1
        break
      fi
      warn "checksum mismatch from $url; trying the next source"
      rm -f "${base_image}.part"
    else
      log "Download failed from $url; trying the next source"
      rm -f "${base_image}.part"
    fi
  done
  [[ "$downloaded" == "1" ]] || die "could not download the pinned base image from any configured source"
fi

verify_sha256 "$base_image" "$ALMA_CLOUD_IMAGE_SHA256" "base image"

work_image="$BUILD_DIR/base/work.qcow2"
rm -f "$work_image"
cp --reflink=auto "$base_image" "$work_image" 2>/dev/null || cp "$base_image" "$work_image"
qemu-img resize "$work_image" "$BUILD_DISK_SIZE"

# Packer verifies the file it actually boots. Resizing changes the qcow2
# checksum, so use the work-image checksum rather than the upstream base
# checksum here. The upstream checksum is still recorded in the manifest.
work_sha256="$(sha256_file "$work_image")"
log "Work image SHA256: $work_sha256"

build_key="$BUILD_DIR/ssh/build_key"
rm -f "$build_key" "${build_key}.pub"
ssh-keygen -q -t ed25519 -N '' -C 'al10-base-build' -f "$build_key"
chmod 600 "$build_key"

build_info="$BUILD_DIR/build-info"
cat >"$build_info" <<EOF
IMAGE_VERSION=${IMAGE_VERSION}
ALMA_CLOUD_IMAGE_URL=${ALMA_CLOUD_IMAGE_URL}
ALMA_CLOUD_IMAGE_SHA256=${ALMA_CLOUD_IMAGE_SHA256}
BUILD_DATE=${BUILD_DATE}
BUILD_GIT_SHA=${BUILD_GIT_SHA}
EOF
chmod 0644 "$build_info"

packer_vars=(
  -var "base_image_path=file://$work_image"
  -var "base_image_checksum=sha256:$work_sha256"
  -var "base_image_sha256=$ALMA_CLOUD_IMAGE_SHA256"
  -var "base_image_url=$ALMA_CLOUD_IMAGE_URL"
  -var "image_version=$IMAGE_VERSION"
  -var "build_git_sha=$BUILD_GIT_SHA"
  -var "build_date=$BUILD_DATE"
  -var "disk_size=$BUILD_DISK_SIZE"
  -var "ssh_public_key=$(cat "${build_key}.pub")"
  -var "ssh_private_key_file=$build_key"
  -var "console_log_path=$BUILD_DIR/console.log"
  -var "build_info_file=$build_info"
  -var "accelerator=$QEMU_ACCEL"
  -var "cpu_model=$QEMU_CPU"
)

validation_vars=(
  "${packer_vars[@]}"
  -var "output_directory=$BUILD_DIR/validate-output"
)

build_vars=(
  "${packer_vars[@]}"
  -var "output_directory=$BUILD_DIR/packer-output"
)

log "Initializing Packer plugins"
(cd packer && "$PACKER_BIN" init . >/dev/null)

log "Validating Packer configuration"
"$PACKER_BIN" validate "${validation_vars[@]}" packer

log "Building image $IMAGE_VERSION"
"$PACKER_BIN" build "${build_vars[@]}" packer

rm -f "$work_image"

built_image="$(find "$BUILD_DIR/packer-output" -maxdepth 1 -type f -name '*.qcow2' -print -quit)"
[[ -n "$built_image" ]] || die "Packer did not produce a qcow2 image"

rm -f "$IMAGE_FILE" "${IMAGE_FILE}.sha256"
mv "$built_image" "$IMAGE_FILE" 2>/dev/null || {
  cp "$built_image" "$IMAGE_FILE"
  rm -f "$built_image"
}
(
  cd "$DIST_DIR"
  sha256sum "$(basename "$IMAGE_FILE")" >"$(basename "$IMAGE_FILE").sha256"
)

cat >"$BUILD_DIR/build.env" <<EOF
BUILD_DATE='${BUILD_DATE}'
BUILD_GIT_SHA='${BUILD_GIT_SHA}'
EOF

scripts/write-manifest.sh

log "Built: $IMAGE_FILE"
log "SHA256: $(sha256_file "$IMAGE_FILE")"
log "Version: $IMAGE_VERSION"
log "Next: make test-qemu"
