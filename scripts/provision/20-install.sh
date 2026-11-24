#!/usr/bin/env bash
set -euxo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# Runtime and integration packages. Application-specific packages belong in
# the downstream Technitium and storage repositories, not in this image.
dnf -y install \
  cloud-init \
  cloud-utils-growpart \
  curl \
  chrony \
  dnf-plugins-core \
  firewalld \
  gzip \
  libselinux-utils \
  openssh-server \
  policycoreutils-python-utils \
  python3 \
  python3-cryptography \
  python3-dnf \
  python3-firewall \
  python3-libselinux \
  qemu-guest-agent \
  sudo \
  tar

dnf clean all
