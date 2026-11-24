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
verify_image_checksum "$IMAGE_FILE"

need_cmd qemu-img
need_cmd qemu-system-x86_64
need_cmd ssh
need_cmd ssh-keygen
need_cmd ssh-keyscan
need_cmd scp
need_cmd python3

qemu_accel
detect_ovmf

test_dir="$BUILD_DIR/test"
rm -rf "$test_dir"
mkdir -p "$test_dir"
mkdir -p "$DIST_DIR"

test_key="$test_dir/test_key"
ssh-keygen -q -t ed25519 -N '' -C "al10-base-test-$(date -u +%Y%m%d%H%M%S)" -f "$test_key"
chmod 600 "$test_key"

user_data="$test_dir/user-data"
meta_data="$test_dir/meta-data"
seed_iso="$test_dir/seed.iso"

cat >"$user_data" <<EOF
#cloud-config
hostname: al10-test
fqdn: al10-test
manage_etc_hosts: true
preserve_hostname: false
ssh_pwauth: false

users:
  - name: ansible
    gecos: Automation
    groups: wheel
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - $(cat "${test_key}.pub")
EOF

cat >"$meta_data" <<EOF
instance-id: al10-base-test-$(date -u +%Y%m%d%H%M%S)
local-hostname: al10-test
EOF

make_seed_iso "$test_dir/seed-work" "$user_data" "$meta_data" "$seed_iso"

overlay="$test_dir/disk.qcow2"
qemu-img create -q -f qcow2 -F qcow2 -b "$IMAGE_FILE" "$overlay" 20G

prepare_ovmf_vars "$test_dir/OVMF_VARS.fd"

known_hosts="$test_dir/known_hosts"
rm -f "$known_hosts"
qemu_log="$test_dir/console.log"
qemu_pid_file="$test_dir/qemu.pid"
qemu_started=0

cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$qemu_started" == "1" && -f "$qemu_pid_file" ]]; then
    local pid
    pid="$(cat "$qemu_pid_file")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      for _ in {1..20}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
      done
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  if [[ "$status" -ne 0 && -f "$qemu_log" ]]; then
    printf '\n===== guest console (tail) =====\n' >&2
    tail -n 120 "$qemu_log" >&2 || true
  fi
  exit "$status"
}
trap cleanup EXIT

log "Booting test VM on 127.0.0.1:${TEST_SSH_PORT}"
qemu-system-x86_64 \
  -name al10-base-test \
  -machine q35 \
  -accel "$QEMU_ACCEL" \
  -cpu "$QEMU_CPU" \
  -smp 2 \
  -m 2048 \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$test_dir/OVMF_VARS.fd" \
  -drive file="$overlay",if=virtio,format=qcow2,cache=writeback,discard=unmap \
  -drive file="$seed_iso",if=virtio,format=raw,readonly=on \
  -device virtio-serial-pci \
  -chardev null,id=qga0 \
  -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${TEST_SSH_PORT}-:22" \
  -device virtio-net-pci,netdev=net0 \
  -display none \
  -serial "file:${qemu_log}" \
  -pidfile "$qemu_pid_file" \
  -daemonize
qemu_started=1
sleep 2
if ! kill -0 "$(cat "$qemu_pid_file")" 2>/dev/null; then
  die "QEMU exited before the test VM booted; see $qemu_log"
fi

if ! wait_for_ssh 127.0.0.1 "$TEST_SSH_PORT" "$test_key" "$known_hosts" 900; then
  die "test VM did not become reachable over SSH"
fi
log "Test VM reached over SSH"

ssh_opts=(
  -i "$test_key"
  -p "$TEST_SSH_PORT"
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile="$known_hosts"
  -o LogLevel=ERROR
)
scp_opts=(
  -i "$test_key"
  -P "$TEST_SSH_PORT"
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile="$known_hosts"
  -o LogLevel=ERROR
)

password_ssh_opts=(
  -p "$TEST_SSH_PORT"
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o PreferredAuthentications=password
  -o PubkeyAuthentication=no
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile="$known_hosts"
  -o LogLevel=ERROR
)

if ssh "${password_ssh_opts[@]}" "ansible@127.0.0.1" true >/dev/null 2>&1; then
  die "SSH password authentication unexpectedly succeeded"
fi
log "SSH password authentication is disabled"

log "Running in-guest contract checks"
ssh "${ssh_opts[@]}" "ansible@127.0.0.1" \
  "sudo -n env IMAGE_VERSION='${IMAGE_VERSION}' bash -s" <"$SCRIPT_DIR/guest-verify.sh"

log "Collecting image metadata"
scp "${scp_opts[@]}" "ansible@127.0.0.1:/var/lib/al10-base/packages.txt" \
  "$DIST_DIR/package-list.txt"
scp "${scp_opts[@]}" "ansible@127.0.0.1:/var/lib/al10-base/image-info.txt" \
  "$DIST_DIR/image-info.txt"

boot_id_before="$(ssh "${ssh_opts[@]}" "ansible@127.0.0.1" 'cat /proc/sys/kernel/random/boot_id')"
host_keys_before="$(ssh-keyscan -p "$TEST_SSH_PORT" -T 5 127.0.0.1 2>/dev/null | sort)"

log "Rebooting guest to verify persistence"
ssh "${ssh_opts[@]}" "ansible@127.0.0.1" 'sudo -n systemctl reboot' || true
sleep 5

boot_id_after="$(wait_for_rebooted_ssh 127.0.0.1 "$TEST_SSH_PORT" "$test_key" "$known_hosts" "$boot_id_before" 900)" \
  || die "test VM did not return after reboot"
log "Guest rebooted (boot_id ${boot_id_after:0:8})"

host_keys_after="$(ssh-keyscan -p "$TEST_SSH_PORT" -T 5 127.0.0.1 2>/dev/null | sort)"
[[ "$host_keys_before" == "$host_keys_after" ]] \
  || die "SSH host keys changed across reboot"

log "Re-running contract checks after reboot"
ssh "${ssh_opts[@]}" "ansible@127.0.0.1" \
  "sudo -n env IMAGE_VERSION='${IMAGE_VERSION}' bash -s" <"$SCRIPT_DIR/guest-verify.sh"

scripts/write-manifest.sh

log "Shutting down test VM"
ssh "${ssh_opts[@]}" "ansible@127.0.0.1" 'sudo -n systemctl poweroff' || true

log "QEMU first-boot test passed"
