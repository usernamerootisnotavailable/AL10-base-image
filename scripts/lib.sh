#!/usr/bin/env bash
# Shared helpers for the AL10 base image build and test scripts.
# This file is sourced, not executed.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

log() {
  printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "this action must run as root on the Proxmox node"
}

require_var() {
  local name=$1
  [[ -n "${!name:-}" ]] || die "required variable is empty or unset: $name"
}

absolute_path() {
  local path=$1
  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$REPO_ROOT" "$path"
  fi
}

load_versions() {
  # shellcheck source=../versions.env
  source "$REPO_ROOT/versions.env"

  IMAGE_BASENAME="almalinux-${IMAGE_VERSION}-${IMAGE_ARCH}.qcow2"
  DIST_DIR="$(absolute_path "${DIST_DIR:-dist}")"
  BUILD_DIR="$(absolute_path "${BUILD_DIR:-.build}")"
  IMAGE_FILE="$(absolute_path "${IMAGE_FILE:-dist/${IMAGE_BASENAME}}")"

  PVE_STORAGE="${PVE_STORAGE:-ZFS-ZR2-Enc}"
  PVE_BRIDGE="${PVE_BRIDGE:-vmbr0}"
  TEMPLATE_VMID="${TEMPLATE_VMID:-9000}"
  TEMPLATE_CORES="${TEMPLATE_CORES:-2}"
  TEMPLATE_MEMORY="${TEMPLATE_MEMORY:-2048}"
  TEMPLATE_CPU="${TEMPLATE_CPU:-x86-64-v2-AES}"
  TEMPLATE_EFI_TYPE="${TEMPLATE_EFI_TYPE:-4m}"
  TEMPLATE_SECURE_BOOT="${TEMPLATE_SECURE_BOOT:-0}"
  TEST_VMID="${TEST_VMID:-9100}"
  TEST_SSH_PORT="${TEST_SSH_PORT:-2222}"
  KEEP_TEST_VM="${KEEP_TEST_VM:-0}"
  ALLOW_TCG="${ALLOW_TCG:-0}"

  export IMAGE_BASENAME DIST_DIR BUILD_DIR IMAGE_FILE
  export PVE_STORAGE PVE_BRIDGE TEMPLATE_VMID TEMPLATE_CORES TEMPLATE_MEMORY
  export TEMPLATE_CPU TEMPLATE_EFI_TYPE TEMPLATE_SECURE_BOOT
  export TEST_VMID TEST_SSH_PORT KEEP_TEST_VM ALLOW_TCG
}

load_build_env() {
  if [[ -f "$BUILD_DIR/build.env" ]]; then
    # shellcheck disable=SC1091
    source "$BUILD_DIR/build.env"
  fi
  BUILD_DATE="${BUILD_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  BUILD_GIT_SHA="${BUILD_GIT_SHA:-$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)}"
  export BUILD_DATE BUILD_GIT_SHA
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

verify_sha256() {
  local file=$1 expected=$2 label=${3:-file}
  [[ -f "$file" ]] || die "$label does not exist: $file"
  local actual
  actual="$(sha256_file "$file")"
  [[ "$actual" == "$expected" ]] || die "$label checksum mismatch: expected $expected, got $actual"
  log "$label checksum verified"
}

verify_image_checksum() {
  local image=$1 sidecar="${1}.sha256"
  [[ -f "$image" ]] || die "image does not exist: $image"
  if [[ -f "$sidecar" ]]; then
    local expected actual
    expected="$(awk 'NR == 1 {print $1}' "$sidecar")"
    actual="$(sha256_file "$image")"
    [[ "$expected" == "$actual" ]] || die "image checksum mismatch: expected $expected, got $actual"
    log "image checksum verified"
  else
    warn "no checksum sidecar for $image; skipping verification"
  fi
}

qemu_accel() {
  if [[ -w /dev/kvm ]]; then
    QEMU_ACCEL=kvm
    QEMU_CPU=host
    export QEMU_ACCEL QEMU_CPU
    return
  fi
  if [[ "$ALLOW_TCG" == "1" ]]; then
    warn "/dev/kvm is not writable; using slow TCG emulation because ALLOW_TCG=1"
    QEMU_ACCEL=tcg
    QEMU_CPU=max
    export QEMU_ACCEL QEMU_CPU
    return
  fi
  die "/dev/kvm is not writable. Run on a KVM-capable host or set ALLOW_TCG=1."
}

detect_ovmf() {
  if [[ -n "${OVMF_CODE:-}" || -n "${OVMF_VARS:-}" ]]; then
    [[ -n "${OVMF_CODE:-}" && -n "${OVMF_VARS:-}" ]] \
      || die "set both OVMF_CODE and OVMF_VARS, or neither"
    [[ -f "$OVMF_CODE" ]] || die "OVMF_CODE does not exist: $OVMF_CODE"
    [[ -f "$OVMF_VARS" ]] || die "OVMF_VARS does not exist: $OVMF_VARS"
    return
  fi

  local pair code vars
  for pair in \
    "/usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd" \
    "/usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd" \
    "/usr/share/edk2/x64/OVMF_CODE.4m.fd:/usr/share/edk2/x64/OVMF_VARS.4m.fd" \
    "/usr/share/edk2/x64/OVMF_CODE.fd:/usr/share/edk2/x64/OVMF_VARS.fd" \
    "/usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd"; do
    code=${pair%%:*}
    vars=${pair#*:}
    if [[ -f "$code" && -f "$vars" ]]; then
      OVMF_CODE=$code
      OVMF_VARS=$vars
      export OVMF_CODE OVMF_VARS
      return
    fi
  done

  die "OVMF firmware not found. Install the 'ovmf' package or set OVMF_CODE and OVMF_VARS."
}

prepare_ovmf_vars() {
  local destination=$1
  detect_ovmf
  mkdir -p "$(dirname "$destination")"
  cp "$OVMF_VARS" "$destination"
  chmod u+w "$destination"
}

make_seed_iso() {
  local workdir=$1 user_data=$2 meta_data=$3 output=$4
  mkdir -p "$workdir"

  if command -v cloud-localds >/dev/null 2>&1; then
    cloud-localds "$output" "$user_data" "$meta_data"
    return
  fi

  local seed_dir="$workdir/seed"
  rm -rf "$seed_dir"
  mkdir -p "$seed_dir"
  cp "$user_data" "$seed_dir/user-data"
  cp "$meta_data" "$seed_dir/meta-data"

  if command -v genisoimage >/dev/null 2>&1; then
    genisoimage -quiet -output "$output" -volid cidata -joliet -rock "$seed_dir"
  elif command -v mkisofs >/dev/null 2>&1; then
    mkisofs -quiet -output "$output" -volid cidata -joliet -rock "$seed_dir"
  elif command -v xorriso >/dev/null 2>&1; then
    xorriso -as mkisofs -quiet -output "$output" -volid cidata -joliet -rock "$seed_dir"
  else
    die "install cloud-localds, genisoimage, mkisofs, or xorriso to create the cloud-init seed"
  fi
}

wait_for_ssh() {
  local host=$1 port=$2 key=$3 known_hosts=$4 timeout=${5:-600}
  local deadline=$((SECONDS + timeout)) keyscan_tmp="${known_hosts}.tmp"

  mkdir -p "$(dirname "$known_hosts")"
  touch "$known_hosts"
  chmod 600 "$known_hosts"

  while (( SECONDS < deadline )); do
    if ssh-keyscan -p "$port" -T 5 "$host" >"$keyscan_tmp" 2>/dev/null \
      && [[ -s "$keyscan_tmp" ]]; then
      sort -u -o "$known_hosts" "$known_hosts" "$keyscan_tmp"
      if ssh \
        -i "$key" \
        -p "$port" \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="$known_hosts" \
        -o LogLevel=ERROR \
        "ansible@${host}" true >/dev/null 2>&1; then
        rm -f "$keyscan_tmp"
        return 0
      fi
    fi
    sleep 3
  done
  rm -f "$keyscan_tmp"
  return 1
}

wait_for_rebooted_ssh() {
  local host=$1 port=$2 key=$3 known_hosts=$4 old_boot_id=$5 timeout=${6:-600}
  local deadline=$((SECONDS + timeout)) boot_id

  while (( SECONDS < deadline )); do
    boot_id="$(ssh \
      -i "$key" \
      -p "$port" \
      -o BatchMode=yes \
      -o ConnectTimeout=10 \
      -o IdentitiesOnly=yes \
      -o StrictHostKeyChecking=yes \
      -o UserKnownHostsFile="$known_hosts" \
      -o LogLevel=ERROR \
      "ansible@${host}" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)"
    if [[ -n "$boot_id" && "$boot_id" != "$old_boot_id" ]]; then
      printf '%s\n' "$boot_id"
      return 0
    fi
    sleep 5
  done
  return 1
}

validate_vmid() {
  [[ "$1" =~ ^[1-9][0-9]{2,8}$ ]] || die "invalid VMID: $1"
}

validate_storage_id() {
  [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_.-]*[A-Za-z0-9]$ ]] \
    || die "invalid Proxmox storage ID: $1"
}

validate_vm_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "invalid VM name: $1"
}

validate_bridge_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "invalid bridge name: $1"
}

validate_boolean() {
  [[ "$1" == "0" || "$1" == "1" ]] || die "expected 0 or 1, got: $1"
}
