#!/usr/bin/env bash
set -euxo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

: "${IMAGE_VERSION:?IMAGE_VERSION is required}"
: "${ALMA_CLOUD_IMAGE_URL:?ALMA_CLOUD_IMAGE_URL is required}"
: "${ALMA_CLOUD_IMAGE_SHA256:?ALMA_CLOUD_IMAGE_SHA256 is required}"
: "${BUILD_DATE:?BUILD_DATE is required}"
: "${BUILD_GIT_SHA:?BUILD_GIT_SHA is required}"

# Wait for cloud-init after the reboot, then require a clean result. Log the
# detailed status before failing so the Packer annotation shows why.
cloud_init_rc=0
cloud-init status --wait || cloud_init_rc=$?
cloud-init status --long || true
if [[ "$cloud_init_rc" -ne 0 ]]; then
  echo "cloud-init status --wait returned $cloud_init_rc" >&2
  exit 1
fi
cloud-init status --format=json | python3 -c '
import json
import sys

data = json.load(sys.stdin)
status = data.get("status")
if status != "done":
    raise SystemExit("cloud-init status is %r" % (status,))
errors = data.get("errors")
if errors:
    raise SystemExit("cloud-init reported errors: %r" % (errors,))
'

[[ "$(getenforce)" == "Enforcing" ]]

# Remove the default cloud user and make ansible the single bootstrap account.
if getent passwd almalinux >/dev/null; then
  userdel -r almalinux
fi

if ! getent passwd ansible >/dev/null; then
  useradd --create-home --shell /bin/bash --groups wheel ansible
fi

usermod --shell /bin/bash --append --groups wheel ansible
usermod --lock ansible
chage --expiredate -1 --maxdays 99999 ansible
install -d -m 0700 -o ansible -g ansible /home/ansible/.ssh

install -m 0440 -o root -g root /dev/null /etc/sudoers.d/90-ansible
printf 'ansible ALL=(ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/90-ansible
visudo -cf /etc/sudoers.d/90-ansible
rm -f /etc/sudoers.d/90-cloud-init-users

# Make ansible the cloud-init default user for both Proxmox and direct
# NoCloud boots. Keep the rest of the shipped default_user settings intact.
python3 - <<'PY'
from pathlib import Path

path = Path("/etc/cloud/cloud.cfg")
lines = path.read_text().splitlines()
out = []
in_system_info = False
in_default_user = False
changed = False

for line in lines:
    if line.startswith("system_info:"):
        in_system_info = True
        in_default_user = False
        out.append(line)
        continue
    if in_system_info and line and not line[0].isspace():
        in_system_info = False
        in_default_user = False
    if in_system_info and line.strip() == "default_user:":
        in_default_user = True
        out.append(line)
        continue
    if in_default_user and line.lstrip().startswith("name:"):
        indent = line[: len(line) - len(line.lstrip())]
        out.append(f"{indent}name: ansible")
        in_default_user = False
        changed = True
        continue
    out.append(line)

if not changed:
    raise SystemExit("could not find system_info.default_user.name in cloud.cfg")

path.write_text("\n".join(out) + "\n")
PY

cat >/etc/cloud/cloud.cfg.d/99-al10-base.cfg <<'EOF'
# Managed by the AL10 base image build.
ssh_pwauth: false
preserve_hostname: false
ssh_deletekeys: true
ssh_genkeytypes:
  - ed25519
  - ecdsa
  - rsa
EOF

cat >/etc/ssh/sshd_config.d/99-al10-base.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF

sshd -t
[[ "$(sshd -T | awk '$1 == "permitrootlogin" {print $2}')" == "no" ]]
[[ "$(sshd -T | awk '$1 == "passwordauthentication" {print $2}')" == "no" ]]

systemctl enable sshd
systemctl start sshd
systemctl enable NetworkManager
systemctl start NetworkManager

systemctl enable --now firewalld
firewall-cmd --state
firewall-cmd --set-default-zone=public
firewall-cmd --permanent --zone=public --add-service=ssh >/dev/null
firewall-cmd --reload
firewall-cmd --zone=public --list-services | grep -qw ssh

systemctl enable --now chronyd
systemctl enable --now qemu-guest-agent

systemctl enable \
  cloud-init-local.service \
  cloud-init.service \
  cloud-config.service \
  cloud-final.service

systemctl set-default multi-user.target

# OVMF has no NVRAM boot entry in a fresh Proxmox template. Install the
# removable-media fallback loader so firmware can boot the ESP without a
# pre-registered efibootmgr entry.
if ! findmnt -rn /boot/efi >/dev/null; then
  efi_device="$(blkid -t TYPE=vfat -o device | awk 'NR == 1 { print; exit }')"
  [[ -n "$efi_device" ]] || {
    echo "/boot/efi is not mounted and no vfat ESP was found" >&2
    exit 1
  }
  mkdir -p /boot/efi
  mount "$efi_device" /boot/efi
fi
efi_source=""
for candidate in /boot/efi/EFI/almalinux /boot/efi/EFI/redhat /boot/efi/EFI/centos; do
  if [[ -d "$candidate" ]]; then
    efi_source="$candidate"
    break
  fi
done
if [[ -z "$efi_source" ]]; then
  echo "No UEFI bootloader in the ESP; installing the removable GRUB fallback"
  dnf -y install grub2-efi-x64 shim-x64
  grub2-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=almalinux \
    --removable
  for candidate in /boot/efi/EFI/almalinux /boot/efi/EFI/redhat /boot/efi/EFI/centos; do
    if [[ -d "$candidate" ]]; then
      efi_source="$candidate"
      break
    fi
  done
fi
[[ -n "$efi_source" ]] || {
  echo "no UEFI bootloader directory found under /boot/efi/EFI" >&2
  exit 1
}
install -d -m 0755 /boot/efi/EFI/BOOT
cp -a "$efi_source"/. /boot/efi/EFI/BOOT/
if [[ -f /boot/efi/EFI/BOOT/shimx64.efi ]]; then
  cp -f /boot/efi/EFI/BOOT/shimx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
elif [[ -f /boot/efi/EFI/BOOT/grubx64.efi ]]; then
  cp -f /boot/efi/EFI/BOOT/grubx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
else
  echo "no shimx64.efi or grubx64.efi found in the ESP" >&2
  exit 1
fi
sync

python3 - <<'PY'
import sys

if sys.version_info < (3, 12):
    raise SystemExit(f"python3 is too old: {sys.version}")

import dnf  # noqa: F401
PY

dnf -q makecache

restorecon -RF /home/ansible /etc/ssh /etc/sudoers.d /etc/cloud

cat >/etc/al10-base-image <<EOF
NAME=al10-base
VERSION=${IMAGE_VERSION}
BASE_IMAGE=${ALMA_CLOUD_IMAGE_URL}
BASE_SHA256=${ALMA_CLOUD_IMAGE_SHA256}
BUILD_DATE=${BUILD_DATE}
GIT_SHA=${BUILD_GIT_SHA}
EOF
chmod 0644 /etc/al10-base-image

grep -q "^VERSION=${IMAGE_VERSION}$" /etc/al10-base-image
grep -A20 'default_user:' /etc/cloud/cloud.cfg | grep -q 'name: ansible'
