#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_versions
cd "$REPO_ROOT"

PACKER_BIN="${PACKER_BIN:-packer}"
need_cmd "$PACKER_BIN"

"$PACKER_BIN" init packer >/dev/null

validation_dir="$BUILD_DIR/validate"
rm -rf "$validation_dir"
mkdir -p "$validation_dir"
need_cmd ssh-keygen
ssh-keygen -q -t ed25519 -N '' -C 'al10-base-validate' -f "$validation_dir/private_key"
: >"$validation_dir/OVMF_CODE.fd"
: >"$validation_dir/OVMF_VARS.fd"

"$PACKER_BIN" validate \
  -var "base_image_path=/nonexistent/base.qcow2" \
  -var "base_image_checksum=sha256:0000000000000000000000000000000000000000000000000000000000000000" \
  -var "base_image_sha256=0000000000000000000000000000000000000000000000000000000000000000" \
  -var "base_image_url=https://example.invalid/base.qcow2" \
  -var "image_version=validate" \
  -var "build_git_sha=validate" \
  -var "build_date=2026-01-01T00:00:00Z" \
  -var "ssh_public_key=$(cat "$validation_dir/private_key.pub")" \
  -var "ssh_private_key_file=$validation_dir/private_key" \
  -var "console_log_path=$validation_dir/console.log" \
  -var "output_directory=$validation_dir/output" \
  -var "ovmf_code=$validation_dir/OVMF_CODE.fd" \
  -var "ovmf_vars=$validation_dir/OVMF_VARS.fd" \
  packer
