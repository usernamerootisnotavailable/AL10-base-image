# AL10 base image

A reproducible AlmaLinux 10 golden image for Proxmox. The image is built from
the official AlmaLinux GenericCloud qcow2 with Packer and QEMU/KVM, tested on
first boot, imported as a Proxmox template, and configured per clone through
Proxmox cloud-init.

This image is the base for:

- [technitium-vm](https://github.com/usernamerootisnotavailable/technitium-vm)
- [storage-vm](https://github.com/usernamerootisnotavailable/storage-vm)

Both repositories expect an AlmaLinux 10 host with an existing `ansible` user,
key-based SSH, and passwordless sudo. Those requirements are part of this
image's contract.

## Current image

| Field | Value |
|---|---|
| Version | `10.3-20261116.0-r1` |
| Base | AlmaLinux 10.3 GenericCloud x86_64, XFS |
| Base build | 2026-11-16 |
| Base SHA256 | `845d3a4e41fde973bdbf9763b62a88538c1a1fadc2332a89f6ea01e2c17c78ee` |
| Virtual disk | 16G, grown by cloud-init after clone resize |
| Firmware | UEFI/OVMF, Secure Boot off |
| Proxmox defaults | VMID 9000, `vmbr0`, `ZFS-ZR2-Enc`, 2 vCPU, 2G RAM |

The default Proxmox storage is `ZFS-ZR2-Enc`. That name is valid for a PVE
storage ID, but the storage must exist before importing the template. Override
it with `PVE_STORAGE` if your pool has a different name.

## Quick start

### Build in GitHub Actions

The free `ubuntu-24.04` runner builds and first-boot-tests the image on every
pull request and push to `main`. The workflow uploads the qcow2, checksum,
package list, and manifest as the `al10-base-image` artifact.

Download the artifact from the workflow run, then import it from a machine
that can reach Proxmox:

```bash
PVE_HOST=root@pve.example \
PVE_STORAGE=ZFS-ZR2-Enc \
make pve-template
```

Proxmox credentials and the guest network are never exposed to public CI.

### Build locally

You need a Linux host with KVM, Packer 1.16.2, QEMU, OVMF, and an ISO creation
tool. See [docs/BUILD.md](docs/BUILD.md).

```bash
make deps-check
make build
make test-qemu
```

The build writes:

```text
dist/almalinux-10.3-20261116.0-r1-x86_64.qcow2
dist/almalinux-10.3-20261116.0-r1-x86_64.qcow2.sha256
dist/build-manifest.json
dist/package-list.txt
dist/image-info.txt
```

### Create the Proxmox template

From a machine with SSH access to the Proxmox node:

```bash
PVE_HOST=root@pve.example \
PVE_STORAGE=ZFS-ZR2-Enc \
TEMPLATE_VMID=9000 \
make pve-template
```

The script copies the image to the node, imports it as a raw disk, creates an
OVMF VM, attaches a cloud-init drive, and converts it to a template. It refuses
to overwrite an existing VMID.

### Clone and configure a VM

```bash
qm clone 9000 201 --name technitium01 --full
qm set 201 \
  --ipconfig0 ip=10.20.0.5/24,gw=10.20.0.1 \
  --nameserver 1.1.1.1 \
  --sshkeys ~/.ssh/ansible.pub
qm resize 201 scsi0 32G
qm start 201
```

Then point the downstream inventory at the VM:

```yaml
all:
  children:
    dns:
      hosts:
        dns01:
          ansible_host: 10.20.0.5
          ansible_user: ansible
```

The first Ansible connection depends on the `ansible` key and passwordless sudo
that the image already provides. The downstream `common` role will harden SSH,
configure firewalld, and start installing services.

Use an upstream resolver such as `1.1.1.1` for the first Technitium deployment.
Do not set the VM's nameserver to its own future DNS address before Technitium
is installed.

### Smoke test on Proxmox

```bash
PVE_HOST=root@pve.example \
TEMPLATE_VMID=9000 \
TEST_VMID=9100 \
make pve-smoke
```

The test clones the template, injects an ephemeral key, starts the VM, waits for
the guest agent, runs the in-guest contract, and destroys the test VM. Set
`KEEP_TEST_VM=1` to keep it for debugging.

## Image contract

The image provides:

- `ansible` user with a locked password, `/bin/bash`, and NOPASSWD sudo
- Key-only SSH with root login disabled
- cloud-init with `ansible` as the default user
- `qemu-guest-agent`, `cloud-init`, `firewalld`, `chronyd`, and `sshd`
- Python 3.12 and `python3-dnf` so Ansible's `dnf` module works
- SELinux enforcing
- firewalld enabled with only the default SSH allowance
- no application packages, secrets, SSH host keys, machine-id, or build key

The downstream repositories own application installation, packages, network
configuration, and service hardening. See
[docs/IMAGE-CONTRACT.md](docs/IMAGE-CONTRACT.md) for the exact contract.

## Documentation

| Document | Purpose |
|---|---|
| [AGENTS.md](AGENTS.md) | Hard rules for changes in this repository |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Build and runtime architecture |
| [docs/IMAGE-CONTRACT.md](docs/IMAGE-CONTRACT.md) | What the image guarantees |
| [docs/BUILD.md](docs/BUILD.md) | Local and CI build instructions |
| [docs/PROXMOX.md](docs/PROXMOX.md) | Template import, cloning, cloud-init, storage |
| [docs/TESTING.md](docs/TESTING.md) | Test layers and known gaps |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Rebuilds, versioning, rollback |

## License

MIT. See [LICENSE](LICENSE).
