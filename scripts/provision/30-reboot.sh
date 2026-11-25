#!/usr/bin/env bash
set -euxo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# Packer is configured with expect_disconnect for this provisioner. Booting
# the newest installed kernel also proves the image can reboot cleanly before
# the final configuration and cleanup steps run.
echo "Rebooting the build VM"
sync
shutdown -r now
