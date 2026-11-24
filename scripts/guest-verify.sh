#!/usr/bin/env bash
set -euo pipefail

# Runs inside the guest as root. The host passes IMAGE_VERSION in the
# environment. Keep this script free of assumptions about the build host.

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

[[ "$(id -u)" -eq 0 ]] || fail "guest verification must run as root"

[[ -f /etc/almalinux-release ]] || fail "/etc/almalinux-release is missing"
grep -q 'AlmaLinux release 10' /etc/almalinux-release || fail "not AlmaLinux 10"
[[ "$(uname -m)" == "x86_64" ]] || fail "architecture is not x86_64"
pass "AlmaLinux 10 x86_64"

getent passwd ansible >/dev/null || fail "ansible user is missing"
runuser -u ansible -- sudo -n true || fail "ansible does not have passwordless sudo"
sudo -l -U ansible | grep -q 'NOPASSWD' || fail "ansible sudoers entry is not NOPASSWD"
[[ "$(getent passwd ansible | cut -d: -f7)" == "/bin/bash" ]] || fail "ansible shell is not bash"
pass "ansible login and passwordless sudo"

sshd_config="$(sshd -T)"
grep -q '^permitrootlogin no$' <<<"$sshd_config" || fail "PermitRootLogin is not no"
grep -q '^passwordauthentication no$' <<<"$sshd_config" || fail "PasswordAuthentication is not no"
grep -q '^pubkeyauthentication yes$' <<<"$sshd_config" || fail "PubkeyAuthentication is not yes"
pass "SSH policy"

cloud-init status --wait >/dev/null || fail "cloud-init did not finish cleanly"
cloud-init status --format=json | python3 -c '
import json
import sys

data = json.load(sys.stdin)
status = data.get("status")
if status != "done":
    raise SystemExit("cloud-init status is %r" % (status,))
if data.get("errors"):
    raise SystemExit("cloud-init errors: %r" % (data["errors"],))
'
pass "cloud-init completed without errors"

for unit in sshd firewalld chronyd qemu-guest-agent; do
  systemctl is-enabled --quiet "$unit" || fail "$unit is not enabled"
  systemctl is-active --quiet "$unit" || fail "$unit is not active"
done
for unit in cloud-init-local cloud-init cloud-config cloud-final; do
  systemctl is-enabled --quiet "$unit" || fail "$unit is not enabled"
done
pass "required services"

[[ "$(getenforce)" == "Enforcing" ]] || fail "SELinux is not Enforcing"
pass "SELinux enforcing"

zone="$(firewall-cmd --get-default-zone)"
[[ "$zone" == "public" ]] || fail "firewalld default zone is $zone"
services="$(firewall-cmd --zone=public --list-services)"
grep -qw ssh <<<"$services" || fail "firewalld does not allow SSH"
for service in http https dns dhcp postgresql mysql; do
  if grep -qw "$service" <<<"$services"; then
    fail "firewalld unexpectedly allows $service"
  fi
done
pass "firewalld defaults"

python3 - <<'PY' || fail "Python or python3-dnf is not usable"
import sys

if sys.version_info < (3, 12):
    raise SystemExit("python3 is too old: %s" % (sys.version,))

import dnf  # noqa: F401
PY
rpm -q python3-dnf >/dev/null || fail "python3-dnf is not installed"
dnf -q makecache >/dev/null || fail "dnf makecache failed"
pass "Python 3.12 and dnf"

for package in \
  cloud-init \
  cloud-utils-growpart \
  qemu-guest-agent \
  python3 \
  python3-dnf \
  sudo \
  openssh-server \
  firewalld \
  chrony; do
  rpm -q "$package" >/dev/null || fail "missing package: $package"
done
pass "baseline packages"

fstype="$(findmnt -no FSTYPE /)"
[[ "$fstype" == "xfs" || "$fstype" == "ext4" ]] || fail "unexpected root filesystem: $fstype"
root_size="$(df -B1 --output=size / | tail -n 1 | tr -d ' ')"
((root_size > 15 * 1024 * 1024 * 1024)) || fail "root filesystem did not grow (${root_size} bytes)"
pass "root filesystem ${fstype} grew to ${root_size} bytes"

[[ -s /etc/machine-id ]] || fail "machine-id is empty after first boot"
[[ "$(tr -d '\n' </etc/machine-id | wc -c)" -eq 32 ]] || fail "machine-id is not 32 hex characters"
host_key_count="$(find /etc/ssh -maxdepth 1 -name 'ssh_host_*_key' | wc -l)"
((host_key_count >= 1)) || fail "no SSH host keys were generated"
pass "machine-id and SSH host keys regenerated"

if grep -R -q 'al10-base-build' /home/ansible/.ssh 2>/dev/null; then
  fail "build SSH key remains in ansible authorized_keys"
fi
if getent passwd almalinux >/dev/null; then
  fail "default almalinux user still exists"
fi
[[ -f /etc/al10-base-image ]] || fail "image version marker is missing"
grep -Fq "VERSION=${IMAGE_VERSION:-}" /etc/al10-base-image \
  || fail "image version marker does not match $IMAGE_VERSION"
[[ -f /var/lib/al10-base/packages.txt ]] || fail "package manifest is missing"
grep -A20 'default_user:' /etc/cloud/cloud.cfg | grep -q 'name: ansible' \
  || fail "cloud-init default user is not ansible"
[[ -s /home/ansible/.ssh/authorized_keys ]] \
  || fail "cloud-init did not inject an SSH key for ansible"
pass "image cleanup and cloud-init user"

printf 'ALL GUEST CHECKS PASSED\n'
