#!/usr/bin/env bash
set -euxo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# Remove every build-time credential and identity artifact. Proxmox cloud-init
# supplies the per-VM SSH key after cloning the template.
rm -f /home/ansible/.ssh/authorized_keys
rm -f /root/.ssh/authorized_keys
rm -f /etc/ssh/ssh_host_*
rm -f /etc/sudoers.d/90-cloud-init-users

if cloud-init clean --help 2>&1 | grep -q -- '--machine-id'; then
  cloud-init clean --logs --seed --machine-id
else
  cloud-init clean --logs --seed
  truncate -s 0 /etc/machine-id
  rm -f /var/lib/dbus/machine-id
fi
rm -rf /var/lib/cloud

rm -f /etc/hostname /etc/machine-info
rm -f /etc/udev/rules.d/70-persistent-net.rules
find /etc/NetworkManager/system-connections -maxdepth 1 -type f -name '*.nmconnection' -delete 2>/dev/null || true

rm -rf /var/log/journal /var/log/anaconda /var/log/qemu-ga /var/log/tuned
find /var/log -type f -exec truncate -s 0 {} + 2>/dev/null || true
find /var/log -type f \( -name '*.gz' -o -name '*.old' -o -name '*.[0-9]' \) -delete

rm -f /root/.bash_history /home/ansible/.bash_history /root/.python_history
rm -f /root/.lesshst /home/ansible/.lesshst

dnf clean all
rm -rf /var/cache/dnf /var/cache/yum /var/lib/dnf/history* /var/log/dnf* /var/log/hawkey.log

# Do not delete the running Packer script itself.
find /tmp -mindepth 1 -maxdepth 1 ! -name "$(basename "$0")" -exec rm -rf {} + 2>/dev/null || true
find /var/tmp -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true

rm -f /var/lib/systemd/random-seed /var/lib/systemd/credential.secret
truncate -s 0 /var/log/audit/audit.log 2>/dev/null || true

if compgen -G '/etc/ssh/ssh_host_*' >/dev/null; then
  echo "SSH host keys still present" >&2
  exit 1
fi
if [[ -s /etc/machine-id ]] && ! grep -qx 'uninitialized' /etc/machine-id; then
  echo "machine-id is populated" >&2
  exit 1
fi
if [[ -d /home/ansible/.ssh ]] && grep -R -q 'al10-base-build' /home/ansible/.ssh; then
  echo "build SSH key still present" >&2
  exit 1
fi

fstrim -av || true
sync
