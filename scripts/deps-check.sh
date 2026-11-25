#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_versions

PACKER_BIN="${PACKER_BIN:-packer}"

need_cmd "$PACKER_BIN"
need_cmd qemu-img
need_cmd qemu-system-x86_64
need_cmd ssh
need_cmd ssh-keygen
need_cmd ssh-keyscan
need_cmd scp
need_cmd curl
need_cmd sha256sum
need_cmd python3

if ! command -v cloud-localds >/dev/null 2>&1 \
  && ! command -v genisoimage >/dev/null 2>&1 \
  && ! command -v mkisofs >/dev/null 2>&1 \
  && ! command -v xorriso >/dev/null 2>&1; then
  die "install cloud-localds, genisoimage, mkisofs, or xorriso"
fi

qemu_accel
detect_ovmf

packer_version="$("$PACKER_BIN" version)"
qemu_version="$(qemu-system-x86_64 --version)"
log "Packer: ${packer_version%%$'\n'*}"
log "QEMU: ${qemu_version%%$'\n'*}"
log "Accelerator: $QEMU_ACCEL"
log "OVMF code: $OVMF_CODE"
log "OVMF vars: $OVMF_VARS"
log "Base image: $ALMA_CLOUD_IMAGE_NAME"
log "Image version: $IMAGE_VERSION"
