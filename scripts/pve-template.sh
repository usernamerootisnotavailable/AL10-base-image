#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_versions
cd "$REPO_ROOT"

TEMPLATE_NAME="${TEMPLATE_NAME:-al10-base-${IMAGE_VERSION}}"
TEMPLATE_DESCRIPTION="${TEMPLATE_DESCRIPTION:-AL10 base image ${IMAGE_VERSION}}"
PVE_REMOTE_DIR="${PVE_REMOTE_DIR:-/var/tmp/al10-base-${IMAGE_VERSION}-$$}"

PVE_SSH_PORT="${PVE_SSH_PORT:-22}"
[[ "$PVE_SSH_PORT" =~ ^[1-9][0-9]{0,4}$ ]] || die "invalid PVE_SSH_PORT: $PVE_SSH_PORT"

ssh_args=(-p "$PVE_SSH_PORT")
scp_args=(-P "$PVE_SSH_PORT")
if [[ -n "${PVE_SSH_OPTS:-}" ]]; then
  read -r -a extra_ssh_opts <<<"$PVE_SSH_OPTS"
  ssh_args+=("${extra_ssh_opts[@]}")
  scp_args+=("${extra_ssh_opts[@]}")
fi

if [[ "${AL10_REMOTE_CHILD:-0}" != "1" && -n "${PVE_HOST:-}" ]]; then
  need_cmd ssh
  need_cmd scp
  require_var IMAGE_FILE
  [[ -f "$IMAGE_FILE" ]] || die "image does not exist: $IMAGE_FILE"
  [[ -f "${IMAGE_FILE}.sha256" ]] \
    || die "checksum sidecar is required: ${IMAGE_FILE}.sha256"
  verify_image_checksum "$IMAGE_FILE"

  remote_image="$PVE_REMOTE_DIR/$(basename "$IMAGE_FILE")"
  log "Copying image to ${PVE_HOST}:${PVE_REMOTE_DIR}"
  ssh "${ssh_args[@]}" "$PVE_HOST" "mkdir -p $(printf '%q' "$PVE_REMOTE_DIR/scripts")"
  scp "${scp_args[@]}" "$IMAGE_FILE" "${IMAGE_FILE}.sha256" \
    "$PVE_HOST:${PVE_REMOTE_DIR}/"
  scp "${scp_args[@]}" "$SCRIPT_DIR/pve-template.sh" "$SCRIPT_DIR/lib.sh" \
    "$PVE_HOST:${PVE_REMOTE_DIR}/scripts/"
  scp "${scp_args[@]}" "$REPO_ROOT/versions.env" "$PVE_HOST:${PVE_REMOTE_DIR}/"

  remote_env=(
    "AL10_REMOTE_CHILD=1"
    "IMAGE_FILE=$remote_image"
    "PVE_STORAGE=$PVE_STORAGE"
    "PVE_BRIDGE=$PVE_BRIDGE"
    "TEMPLATE_VMID=$TEMPLATE_VMID"
    "TEMPLATE_NAME=$TEMPLATE_NAME"
    "TEMPLATE_DESCRIPTION=$TEMPLATE_DESCRIPTION"
    "TEMPLATE_CORES=$TEMPLATE_CORES"
    "TEMPLATE_MEMORY=$TEMPLATE_MEMORY"
    "TEMPLATE_CPU=$TEMPLATE_CPU"
    "TEMPLATE_EFI_TYPE=$TEMPLATE_EFI_TYPE"
    "TEMPLATE_SECURE_BOOT=$TEMPLATE_SECURE_BOOT"
  )
  remote_env_string=""
  for item in "${remote_env[@]}"; do
    remote_env_string+="$(printf '%q' "$item") "
  done

  remote_cmd="sudo -n env ${remote_env_string}bash $(printf '%q' "$PVE_REMOTE_DIR/scripts/pve-template.sh")"
  log "Creating template on $PVE_HOST"
  if ssh "${ssh_args[@]}" "$PVE_HOST" "$remote_cmd"; then
    if [[ "${KEEP_REMOTE_IMAGE:-0}" == "1" ]]; then
      log "Keeping remote image at ${PVE_HOST}:${PVE_REMOTE_DIR}"
    else
      ssh "${ssh_args[@]}" "$PVE_HOST" \
        "sudo -n rm -rf $(printf '%q' "$PVE_REMOTE_DIR")" \
        || warn "template created, but remote temporary files remain at ${PVE_HOST}:${PVE_REMOTE_DIR}"
    fi
  else
    warn "Template creation failed; remote files remain at ${PVE_HOST}:${PVE_REMOTE_DIR}"
    exit 1
  fi
  exit 0
fi

require_root
need_cmd qm
need_cmd pvesm
need_cmd qemu-img
need_cmd sha256sum

require_var IMAGE_FILE
require_var PVE_STORAGE
require_var PVE_BRIDGE
require_var TEMPLATE_VMID
require_var TEMPLATE_NAME
require_var TEMPLATE_CORES
require_var TEMPLATE_MEMORY
require_var TEMPLATE_CPU

validate_vmid "$TEMPLATE_VMID"
validate_storage_id "$PVE_STORAGE"
validate_bridge_id "$PVE_BRIDGE"
validate_vm_name "$TEMPLATE_NAME"
validate_boolean "$TEMPLATE_SECURE_BOOT"
[[ "$TEMPLATE_EFI_TYPE" == "2m" || "$TEMPLATE_EFI_TYPE" == "4m" ]] \
  || die "TEMPLATE_EFI_TYPE must be 2m or 4m"
[[ "$TEMPLATE_CORES" =~ ^[1-9][0-9]*$ ]] || die "invalid TEMPLATE_CORES: $TEMPLATE_CORES"
[[ "$TEMPLATE_MEMORY" =~ ^[1-9][0-9]*$ ]] || die "invalid TEMPLATE_MEMORY: $TEMPLATE_MEMORY"
(( ${#TEMPLATE_NAME} <= 63 )) || die "template name is longer than 63 characters"

[[ -f "$IMAGE_FILE" ]] || die "image does not exist: $IMAGE_FILE"
[[ -f "${IMAGE_FILE}.sha256" ]] \
  || die "checksum sidecar is required: ${IMAGE_FILE}.sha256"
verify_image_checksum "$IMAGE_FILE"

pvesm status --content images \
  | awk -v storage="$PVE_STORAGE" '$1 == storage { found = 1 } END { exit !found }' \
  || die "Proxmox storage '$PVE_STORAGE' does not exist, is inactive, or does not support images"
qemu-img info "$IMAGE_FILE" >/dev/null

if qm status "$TEMPLATE_VMID" >/dev/null 2>&1; then
  die "VMID $TEMPLATE_VMID already exists; choose a free TEMPLATE_VMID"
fi

description="$TEMPLATE_DESCRIPTION
Base image: $ALMA_CLOUD_IMAGE_URL
Base SHA256: $ALMA_CLOUD_IMAGE_SHA256
Built by: https://github.com/usernamerootisnotavailable/AL10-base-image"

log "Creating VM $TEMPLATE_VMID ($TEMPLATE_NAME)"
qm create "$TEMPLATE_VMID" \
  --name "$TEMPLATE_NAME" \
  --description "$description" \
  --memory "$TEMPLATE_MEMORY" \
  --cores "$TEMPLATE_CORES" \
  --cpu "$TEMPLATE_CPU" \
  --ostype l26 \
  --machine q35 \
  --scsihw virtio-scsi-single \
  --bios ovmf \
  --efidisk0 "${PVE_STORAGE}:1,efitype=${TEMPLATE_EFI_TYPE},pre-enrolled-keys=${TEMPLATE_SECURE_BOOT}" \
  --agent enabled=1 \
  --net0 "virtio,bridge=${PVE_BRIDGE}" \
  --tags "almalinux;10;base;golden" \
  --onboot 0

log "Importing disk"
qm importdisk "$TEMPLATE_VMID" "$IMAGE_FILE" "$PVE_STORAGE" --format raw

volume="$(qm config "$TEMPLATE_VMID" | awk -F': ' '/^unused0:/ {print $2; exit}')"
[[ -n "$volume" ]] || die "could not find the imported disk on VM $TEMPLATE_VMID"

qm set "$TEMPLATE_VMID" \
  --scsi0 "${volume},discard=on,ssd=1,iothread=1"

log "Configuring cloud-init and boot order"
qm set "$TEMPLATE_VMID" --ide2 "${PVE_STORAGE}:cloudinit"
qm set "$TEMPLATE_VMID" --ciuser ansible --ipconfig0 ip=dhcp
qm set "$TEMPLATE_VMID" --boot order=scsi0

log "Converting VM $TEMPLATE_VMID to a template"
qm template "$TEMPLATE_VMID"

log "Template created: $TEMPLATE_NAME (VMID $TEMPLATE_VMID)"
qm config "$TEMPLATE_VMID"
