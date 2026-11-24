#!/usr/bin/env bash
set -euxo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

[[ -f /etc/almalinux-release ]]
grep -q 'AlmaLinux release 10' /etc/almalinux-release
[[ "$(uname -m)" == "x86_64" ]]

# Start from the current AlmaLinux 10 package set. The build records the
# resulting package list in /var/lib/al10-base/packages.txt.
dnf -y upgrade --refresh
