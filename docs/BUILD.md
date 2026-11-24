# Building the Image

## Prerequisites

The build needs a Linux host with hardware virtualization. CI uses the free
`ubuntu-24.04` GitHub-hosted runner; locally, use a machine with `/dev/kvm`.

| Requirement | Notes |
|---|---|
| Packer | 1.16.2 is pinned in CI; the QEMU plugin is pinned in HCL |
| QEMU | `qemu-system-x86_64` and `qemu-img` |
| OVMF | UEFI code and variable firmware files |
| ISO tool | `cloud-localds`, `genisoimage`, `mkisofs`, or `xorriso` |
| SSH | `ssh`, `scp`, `ssh-keygen`, `ssh-keyscan` |
| Hashing | `sha256sum` |
| Python | 3.9+ for the manifest and helper scripts |
| KVM | `/dev/kvm` must be readable and writable |

### Debian / Ubuntu

```bash
sudo apt-get install -y \
  cloud-image-utils \
  ovmf \
  qemu-system-x86 \
  qemu-utils \
  xorriso
```

Install Packer 1.16.2 from HashiCorp or use the CI workflow.

### Arch Linux

```bash
sudo pacman -S --needed \
  cloud-utils \
  edk2-ovmf \
  libisoburn \
  packer \
  qemu-base
```

`cloud-utils` provides `cloud-localds`; `libisoburn` provides `xorriso`.

### KVM check

```bash
test -r /dev/kvm && test -w /dev/kvm
```

On a host where the current user cannot write `/dev/kvm`, add the user to the
`kvm` group or adjust permissions. For a slow software-emulation build, use
`ALLOW_TCG=1`; this is not suitable for normal CI.

## Lint tools

`make lint` expects Packer, ShellCheck, yamllint 1.38.0, `npx` for
`markdownlint-cli2` 0.24.2, and optionally gitleaks 8.30.1. CI installs the
pinned versions; locally, install them with your package manager or use the
same versions in a virtual environment.

## Build

```bash
make deps-check
make build
make test-qemu
```

The build:

1. Downloads the pinned AlmaLinux GenericCloud qcow2 into `.build/base/`.
2. Verifies the SHA256 from `versions.env`.
3. Resizes a work copy to `BUILD_DISK_SIZE` (16G).
4. Generates an ephemeral build SSH key.
5. Boots the qcow2 under QEMU/KVM with UEFI and a temporary NoCloud seed.
6. Runs `dnf upgrade`, installs the baseline, configures users and services,
   records the package manifest, cleans first-boot state, and shuts down.
7. Copies the qcow2 into `dist/` with a checksum and manifest.

`make test-qemu` boots the artifact with a fresh 20G overlay and a new cloud-init
seed, verifies the contract, reboots it, and verifies persistence.

## Outputs

```text
dist/
  almalinux-10.3-20261116.0-r1-x86_64.qcow2
  almalinux-10.3-20261116.0-r1-x86_64.qcow2.sha256
  build-manifest.json
  package-list.txt
  image-info.txt
```

`build-manifest.json` records the artifact hash and size, base image URL and
checksum, AlmaLinux release, build date, git commit, and file names.

## Useful variables

| Variable | Default | Purpose |
|---|---|---|
| `PACKER_BIN` | `packer` | Packer executable |
| `BUILD_DIR` | `.build` | Download, keys, Packer output, test state |
| `DIST_DIR` | `dist` | Published artifact directory |
| `IMAGE_FILE` | `dist/almalinux-<version>-x86_64.qcow2` | Artifact path |
| `ALLOW_TCG` | `0` | Allow slow TCG emulation when KVM is unavailable |
| `BASE_IMAGE_FILE` | unset | Use a pre-downloaded base qcow2 instead of downloading |
| `OVMF_CODE` / `OVMF_VARS` | auto-detected | Explicit OVMF firmware paths |
| `TEST_SSH_PORT` | `2222` | Host-forwarded SSH port for the QEMU test |

Example offline build:

```bash
BASE_IMAGE_FILE=/srv/images/AlmaLinux-10-GenericCloud-10.3-20261116.0.x86_64.qcow2 \
  make build
```

## Updating the base image

1. Find the new AlmaLinux GenericCloud x86_64 qcow2 and its SHA256 in the
   upstream `CHECKSUM` file.
2. Update `ALMA_RELEASE`, `ALMA_IMAGE_DATE`, `ALMA_CLOUD_IMAGE_NAME`,
   `ALMA_CLOUD_IMAGE_URL`, `ALMA_CLOUD_IMAGE_SHA256`, and `IMAGE_VERSION` in
   `versions.env`.
3. Run `make build` and `make test-qemu`.
4. Import a new template with a new VMID; do not overwrite the previous
   template.
5. Run `make pve-smoke`.
6. Validate a downstream deployment and then retire the old template.

Do not update the base image as part of an unrelated change.

## CI

`.github/workflows/build.yml` builds on every pull request, push to `main`, tag,
and manual dispatch. It:

- frees runner disk space
- installs QEMU, OVMF, cloud-image-utils, and xorriso
- verifies `/dev/kvm`
- builds with Packer
- runs the QEMU first-boot test
- uploads the image, checksum, manifest, package list, and image info

The public workflow has no Proxmox credentials. Import and the Proxmox smoke test
run from a trusted machine.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `/dev/kvm is not writable` | KVM not exposed, or the user lacks permissions. Use a KVM host or `ALLOW_TCG=1` for a slow local build. |
| `OVMF firmware not found` | Install the `ovmf`/`edk2-ovmf` package or set `OVMF_CODE` and `OVMF_VARS`. |
| Packer cannot connect | The temporary seed did not create `ansible`, or cloud-init could not parse the seed. Check `.build/packer-output/console.log`. |
| Cloud-init status is not done | Inspect the console log and `journalctl -u cloud-init` inside the build VM. |
| Disk full on CI | Re-run with the disk-space step; remove `.build` artifacts and avoid retaining multiple qcow2 files. |
| Test VM does not reboot | Check the console log and QEMU process; the reboot test reuses the existing host key entry. |
