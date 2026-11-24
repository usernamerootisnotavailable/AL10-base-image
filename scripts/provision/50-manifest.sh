#!/usr/bin/env bash
set -euxo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

: "${IMAGE_VERSION:?IMAGE_VERSION is required}"
: "${ALMA_CLOUD_IMAGE_URL:?ALMA_CLOUD_IMAGE_URL is required}"
: "${ALMA_CLOUD_IMAGE_SHA256:?ALMA_CLOUD_IMAGE_SHA256 is required}"
: "${BUILD_DATE:?BUILD_DATE is required}"
: "${BUILD_GIT_SHA:?BUILD_GIT_SHA is required}"

install -d -m 0755 /var/lib/al10-base

rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' \
  | LC_ALL=C sort >/var/lib/al10-base/packages.txt

{
  printf 'IMAGE_VERSION=%s\n' "$IMAGE_VERSION"
  printf 'BUILD_DATE=%s\n' "$BUILD_DATE"
  printf 'GIT_SHA=%s\n' "$BUILD_GIT_SHA"
  printf 'BASE_IMAGE=%s\n' "$ALMA_CLOUD_IMAGE_URL"
  printf 'BASE_SHA256=%s\n' "$ALMA_CLOUD_IMAGE_SHA256"
  printf 'KERNEL=%s\n' "$(uname -r)"
  printf 'ROOT_FSTYPE=%s\n' "$(findmnt -no FSTYPE /)"
  printf 'CLOUD_INIT=%s\n' "$(rpm -q --qf '%{VERSION}-%{RELEASE}' cloud-init)"
  printf 'QEMU_GUEST_AGENT=%s\n' "$(rpm -q --qf '%{VERSION}-%{RELEASE}' qemu-guest-agent)"
  printf 'PYTHON=%s\n' "$(python3 --version 2>&1)"
} >/var/lib/al10-base/image-info.txt

chmod 0644 /var/lib/al10-base/packages.txt /var/lib/al10-base/image-info.txt
