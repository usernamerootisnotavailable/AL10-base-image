#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_versions
cd "$REPO_ROOT"

require_var PVE_HOST
require_var TEMPLATE_VMID
validate_vmid "$TEMPLATE_VMID"
validate_vmid "$TEST_VMID"
[[ "$TEST_VMID" != "$TEMPLATE_VMID" ]] || die "TEST_VMID must differ from TEMPLATE_VMID"

TEST_NAME="${TEST_NAME:-al10-smoke-${TEST_VMID}}"
TEST_IP="${TEST_IP:-}"
TEST_IPCONFIG="${TEST_IPCONFIG:-ip=dhcp}"
TEST_NAMESERVER="${TEST_NAMESERVER:-}"
TEST_DISK_SIZE="${TEST_DISK_SIZE:-20G}"
PVE_TEST_SSH_PORT="${PVE_TEST_SSH_PORT:-22}"
TEST_SSH_KEY="${TEST_SSH_KEY:-$BUILD_DIR/test/pve_smoke_key}"

validate_vm_name "$TEST_NAME"
[[ "$TEST_NAME" == al10-smoke-* ]] || die "TEST_NAME must start with al10-smoke-"

PVE_SSH_PORT="${PVE_SSH_PORT:-22}"
[[ "$PVE_SSH_PORT" =~ ^[1-9][0-9]{0,4}$ ]] || die "invalid PVE_SSH_PORT: $PVE_SSH_PORT"
[[ "$PVE_TEST_SSH_PORT" =~ ^[1-9][0-9]{0,4}$ ]] || die "invalid PVE_TEST_SSH_PORT: $PVE_TEST_SSH_PORT"
[[ "$TEST_DISK_SIZE" =~ ^[1-9][0-9]*[GMT]$ ]] || die "invalid TEST_DISK_SIZE: $TEST_DISK_SIZE"

ssh_args=(-p "$PVE_SSH_PORT")
scp_args=(-P "$PVE_SSH_PORT")
if [[ -n "${PVE_SSH_OPTS:-}" ]]; then
  read -r -a extra_ssh_opts <<<"$PVE_SSH_OPTS"
  ssh_args+=("${extra_ssh_opts[@]}")
  scp_args+=("${extra_ssh_opts[@]}")
fi

need_cmd ssh
need_cmd scp
need_cmd ssh-keygen
need_cmd ssh-keyscan
need_cmd python3

pve() {
  local command=""
  local arg
  for arg in "$@"; do
    command+="$(printf '%q' "$arg") "
  done
  ssh "${ssh_args[@]}" "$PVE_HOST" "sudo -n ${command}"
}

mkdir -p "$(dirname "$TEST_SSH_KEY")"
rm -f "$TEST_SSH_KEY" "${TEST_SSH_KEY}.pub"
ssh-keygen -q -t ed25519 -N '' -C "al10-smoke-$(date -u +%Y%m%d%H%M%S)" -f "$TEST_SSH_KEY"
chmod 600 "$TEST_SSH_KEY"

remote_key="/var/tmp/${TEST_NAME}.pub"
test_vm_created=0

cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$KEEP_TEST_VM" == "1" ]]; then
    log "KEEP_TEST_VM=1; leaving VM $TEST_VMID in place"
  elif [[ "$test_vm_created" == "1" ]]; then
    pve qm stop "$TEST_VMID" --skiplock >/dev/null 2>&1 || true
    sleep 2
    pve qm destroy "$TEST_VMID" --purge --skiplock >/dev/null 2>&1 || true
  fi
  ssh "${ssh_args[@]}" "$PVE_HOST" "rm -f $(printf '%q' "$remote_key")" >/dev/null 2>&1 || true
  if [[ "$status" -ne 0 ]]; then
    {
      printf '\n===== template config =====\n'
      pve qm config "$TEMPLATE_VMID" || true
      if [[ "$test_vm_created" == "1" ]]; then
        printf '\n===== test VM config =====\n'
        pve qm config "$TEST_VMID" || true
      fi
    } >&2
  fi
  exit "$status"
}
trap cleanup EXIT

if ! pve qm status "$TEMPLATE_VMID" >/dev/null 2>&1; then
  die "template VMID $TEMPLATE_VMID does not exist on $PVE_HOST"
fi
if pve qm status "$TEST_VMID" >/dev/null 2>&1; then
  die "test VMID $TEST_VMID already exists on $PVE_HOST"
fi

template_config="$(pve qm config "$TEMPLATE_VMID")"
grep -q '^bios: ovmf$' <<<"$template_config" || die "template is not UEFI/OVMF"
grep -q '^efidisk0:' <<<"$template_config" || die "template has no EFI disk"
grep -q '^agent: 1' <<<"$template_config" || die "template does not enable the QEMU guest agent"
grep -q 'cloudinit' <<<"$template_config" || die "template has no cloud-init drive"
grep -q '^ciuser: ansible$' <<<"$template_config" || die "template cloud-init user is not ansible"

log "Cloning template $TEMPLATE_VMID to $TEST_VMID"
pve qm clone "$TEMPLATE_VMID" "$TEST_VMID" --name "$TEST_NAME" --full
test_vm_created=1

scp "${scp_args[@]}" "${TEST_SSH_KEY}.pub" "$PVE_HOST:$remote_key"
pve qm set "$TEST_VMID" --sshkeys "$remote_key"
pve qm set "$TEST_VMID" --ipconfig0 "$TEST_IPCONFIG"
if [[ -n "$TEST_NAMESERVER" ]]; then
  pve qm set "$TEST_VMID" --nameserver "$TEST_NAMESERVER"
fi
pve qm resize "$TEST_VMID" scsi0 "$TEST_DISK_SIZE"
pve qm start "$TEST_VMID"

log "Waiting for the guest agent"
agent_ready=0
for _ in $(seq 1 120); do
  if pve qm agent "$TEST_VMID" ping >/dev/null 2>&1; then
    agent_ready=1
    break
  fi
  sleep 5
done
[[ "$agent_ready" == "1" ]] || die "guest agent did not respond within 10 minutes"

if [[ -z "$TEST_IP" ]]; then
  log "Discovering guest IP address"
  for _ in $(seq 1 60); do
    interfaces_json="$(pve qm guest cmd "$TEST_VMID" network-get-interfaces 2>/dev/null || true)"
    TEST_IP="$(printf '%s' "$interfaces_json" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    raise SystemExit(1)

for interface in data:
    if interface.get("name") == "lo":
        continue
    for address in interface.get("ip-addresses", []):
        if address.get("ip-address-type") != "ipv4":
            continue
        value = address.get("ip-address", "")
        if value and not value.startswith("127."):
            print(value)
            raise SystemExit(0)

raise SystemExit(1)
' 2>/dev/null || true)"
    [[ -n "$TEST_IP" ]] && break
    sleep 5
  done
fi
[[ -n "$TEST_IP" ]] || die "could not discover the guest IPv4 address"

log "Guest IP: $TEST_IP"
known_hosts="$BUILD_DIR/test/pve_known_hosts"
rm -f "$known_hosts"
if ! wait_for_ssh "$TEST_IP" "$PVE_TEST_SSH_PORT" "$TEST_SSH_KEY" "$known_hosts" 600; then
  die "guest did not become reachable over SSH at $TEST_IP:$PVE_TEST_SSH_PORT"
fi

ssh_opts=(
  -i "$TEST_SSH_KEY"
  -p "$PVE_TEST_SSH_PORT"
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile="$known_hosts"
  -o LogLevel=ERROR
)

log "Running in-guest contract checks over SSH"
ssh "${ssh_opts[@]}" "ansible@${TEST_IP}" \
  "sudo -n env IMAGE_VERSION='${IMAGE_VERSION}' bash -s" <"$SCRIPT_DIR/guest-verify.sh"

if [[ "${RUN_CONTRACT:-0}" == "1" ]]; then
  need_cmd ansible-playbook
  log "Running Ansible contract playbook"
  ansible-playbook \
    -i "${TEST_IP}," \
    -u ansible \
    --private-key "$TEST_SSH_KEY" \
    -e "ansible_ssh_common_args=-o StrictHostKeyChecking=yes -o UserKnownHostsFile=${known_hosts}" \
    tests/contract/playbook.yml
fi

log "Proxmox smoke test passed for template $TEMPLATE_VMID"
