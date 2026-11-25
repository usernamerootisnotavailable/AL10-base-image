# Architecture

## Purpose

This repository produces one versioned AlmaLinux 10 golden image and a Proxmox
template built from it. The image provides the minimum host baseline needed for
the downstream Technitium and storage repositories to connect with Ansible and
apply their own service configuration.

It does not configure DNS, DHCP, databases, object storage, search, TLS, or
application secrets.

## Pipeline

```text
Pinned AlmaLinux GenericCloud qcow2
              │
              ▼
Packer + QEMU/KVM + temporary cloud-init seed
              │
              ▼
SSH provisioning: updates, baseline packages, ansible user, services
              │
              ▼
Cleanup: remove build key, host keys, machine-id, cloud-init state, logs
              │
              ▼
Versioned qcow2 + SHA256 + package manifest
              │
              ├── QEMU first-boot test + reboot test
              │
              ▼
Proxmox import: raw disk, OVMF, virtio-scsi-single, cloud-init drive
              │
              ▼
Proxmox template
              │
              ▼
qm clone + Proxmox cloud-init (hostname, key, address)
              │
              ▼
Downstream Ansible repositories
```

The build-time cloud-init seed creates a temporary `ansible` login for Packer.
The final cleanup removes that key and all cloud-init instance state. At clone
time, Proxmox's cloud-init drive is the only source of per-VM identity and
access.

## Boundaries

| Layer | Owns |
|---|---|
| This repository | AlmaLinux base image, baseline packages, `ansible` access, cloud-init, guest agent, SELinux/firewalld state, image cleanup, Proxmox template import, first-boot tests |
| Proxmox | VM identity, CPU/memory/disk sizing, cloud-init drive, per-clone hostname, SSH key injection, DHCP or static address, guest agent channel, snapshots and backups |
| technitium-vm | Podman, Technitium, NGINX, Certbot, DNS/DHCP firewall exposure, Technitium web UI configuration |
| storage-vm | PostgreSQL, MariaDB, Garage, Elasticsearch, NGINX, certificates, service firewall rules, backups |
| External platform | Off-host backups, disaster recovery, public DNS, TLS accounts, Proxmox cluster operations |

## Locked decisions

| Decision | Choice | Consequence |
|---|---|---|
| Base image | Official AlmaLinux GenericCloud qcow2 | Fast, reproducible builds with AlmaLinux-maintained drivers and cloud-init |
| Build tool | Packer + QEMU/KVM | Boot-time provisioning and a testable artifact before Proxmox sees it |
| Firmware | UEFI/OVMF, Secure Boot off initially | Matches a UEFI-standardized Proxmox environment without adding Secure Boot variables to the first template. Packer provisions under BIOS and installs the ESP removable fallback loader used by OVMF. |
| Filesystem | XFS | Matches the default AlmaLinux GenericCloud image and downstream enterprise Linux expectations |
| Disk | 16G virtual | Small template; clones are resized before first boot when services need more space |
| Bootstrap account | `ansible`, NOPASSWD sudo | Required by both downstream repositories and their development harnesses |
| SSH | Key-only, root login disabled | No password or root path into a production host |
| Identity | Proxmox cloud-init per clone | No hostname, key, machine-id, or static address baked into the template |
| Network | One virtio NIC, DHCP by default | Downstream expects a single LAN interface (`ens18`) with a default route; static address is set per clone |
| Application scope | None | Downstream repositories remain the source of truth for services |
| Storage example | `ZFS-ZR2-Enc` | Valid PVE storage ID; must exist before import |

## Security model

- The base image enforces SELinux targeting and leaves SELinux enforcing.
- firewalld is enabled with the default `public` zone and its default SSH
  allowance. The downstream `common` roles replace the broad SSH rule with
  explicit source CIDRs.
- No application ports are open.
- The `ansible` account has passwordless sudo because Ansible must escalate.
  The account has a locked password and accepts keys only.
- Build and test private keys are generated in `.build/` and are never
  committed. The final image contains no authorized key.
- Host keys and machine-id are removed; cloud-init regenerates them on the first
  clone boot.
- The image contains no secrets, production addresses, or real hostnames.
- Proxmox import uses SSH, not an API token in CI.
- The qcow2 is verified against its SHA256 sidecar before import.

## Failure domains

- A bad base image or Packer build fails before Proxmox is touched.
- A bad first-boot configuration fails the QEMU test before an artifact is
  published.
- A bad UEFI or cloud-init configuration fails the Proxmox clone smoke test.
- A bad downstream role fails in the downstream repository, not here.
- Proxmox storage loss, VM loss, and backups remain outside this repository.

## Upgrade path

The base image is versioned, not mutated in place. A new AlmaLinux cloud image
or a baseline change produces a new qcow2, a new checksum, and a new template
name. Old templates remain available for rollback until the new one has passed
both test layers and the downstream repositories have been validated.

See `docs/OPERATIONS.md` for the rebuild and rollback procedure.
