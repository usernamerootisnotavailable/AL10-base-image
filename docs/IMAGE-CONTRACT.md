# Image Contract

This document defines what the golden image guarantees and what it deliberately
does not do. Downstream repositories may rely on this contract.

## Platform

| Item | Guarantee |
|---|---|
| Distribution | AlmaLinux 10 |
| Architecture | x86_64 |
| Base variant | GenericCloud, XFS root |
| Firmware | Boots under UEFI/OVMF and BIOS |
| Disk | 16G virtual image; root grows on first boot after clone resize |
| Time | `chronyd` installed and enabled; default AlmaLinux time sources |
| Init | systemd |
| SELinux | Enforcing, targeted policy |

## Access

| Item | Guarantee |
|---|---|
| Bootstrap user | `ansible` |
| Shell | `/bin/bash` |
| Password | Locked; no password login |
| Sudo | `ansible ALL=(ALL) NOPASSWD: ALL` |
| SSH service | `sshd` enabled and active |
| SSH authentication | Public key only |
| Root login | Disabled |
| Per-VM key | Supplied by Proxmox cloud-init, not baked into the image |
| SSH host keys | Removed at build; regenerated on first boot |

The downstream inventories use `ansible_user: ansible` and expect passwordless
sudo. Their `common` role does not create this account.

## Cloud-init

| Item | Guarantee |
|---|---|
| Package | Installed |
| Datasources | NoCloud and ConfigDrive supported (Proxmox cloud-init drive works) |
| Default user | `ansible` |
| SSH password auth | Disabled |
| Hostname | Supplied by cloud metadata; not preserved from the build |
| Root filesystem growth | `cloud-utils-growpart` and cloud-init growpart enabled |
| Host keys | Regenerated on first boot |
| Instance state | Empty in the template; clones start a fresh instance |
| Network | DHCP by default; Proxmox may set a static address |

The template's Proxmox settings use `ciuser=ansible` and `ipconfig0 ip=dhcp`.
A clone may override the address and inject a key in the Proxmox UI or with
`qm set`.

## Services and baseline packages

Enabled services:

- `sshd`
- `firewalld`
- `chronyd`
- `qemu-guest-agent`
- `cloud-init-local`, `cloud-init`, `cloud-config`, `cloud-final`

Installed package families:

- cloud-init and growpart support
- QEMU guest agent
- OpenSSH server
- Python 3.12 and `python3-dnf`
- sudo
- firewalld and its Python bindings
- chrony
- SELinux and firewall Python bindings
- DNF plugins and basic archive utilities

The image does not install:

- Podman or Docker
- NGINX, Certbot, or OpenSSL application configuration
- PostgreSQL, MariaDB, Garage, or Elasticsearch
- Technitium
- EPEL or vendor application repositories
- monitoring, backup, or configuration-management agents

The downstream `common` roles install their own package sets. Installing a
baseline package here is only to make the first Ansible run possible; it does
not replace the downstream roles.

## Network

- One virtio network interface. On Proxmox this normally appears as `ens18`.
- No static address, gateway, nameserver, or search domain is baked in.
- Proxmox cloud-init supplies DHCP or a static address per clone.
- The downstream Technitium host requires one LAN interface with a default
  route. The template follows that assumption.
- Use a reachable upstream resolver for the first Technitium deployment; do not
  point the host at its own future DNS service before Technitium is running.

## Firewall

- firewalld is enabled and active.
- The default zone is `public`.
- The only allowed service is the distribution default SSH access. The base
  image does not open HTTP, HTTPS, DNS, DHCP, database, or application ports.
- Downstream roles replace the broad SSH allowance with source-CIDR rules and
  add their own service exposure.

## Filesystem and identity

The finalized image does not contain:

- a build or test SSH authorized key
- SSH host private keys
- a populated `/etc/machine-id`
- `/etc/hostname` or `/etc/machine-info` from the build
- NetworkManager connection profiles from the build
- `/var/lib/cloud` instance data
- build shell history, package cache, DNF history, or build logs

The image does contain:

- `/etc/al10-base-image` with the image version, base image URL, base checksum,
  build date, and git commit
- `/var/lib/al10-base/packages.txt` with the installed package list
- `/var/lib/al10-base/image-info.txt` with kernel, filesystem, cloud-init, and
  guest-agent versions

## Version marker

```text
NAME=al10-base
VERSION=<image version>
BASE_IMAGE=<upstream URL>
BASE_SHA256=<upstream checksum>
BUILD_DATE=<UTC timestamp>
GIT_SHA=<commit>
```

## Explicit non-goals

- Application configuration
- Production secrets
- Public DNS or certificate issuance
- Backups or disaster recovery
- High availability
- Multi-NIC, VLAN, or router topologies
- Secure Boot enablement in the first template
- Automatic in-place upgrades of a running VM

## Downstream expectations

A clone is ready for the downstream repositories when:

1. Proxmox cloud-init has injected the `ansible` key.
2. The VM has a reachable address and default route.
3. `ssh ansible@<address>` succeeds.
4. `sudo -n true` succeeds as `ansible`.
5. `python3 -c 'import dnf'` succeeds.
6. SELinux is enforcing and firewalld is running.
7. `qemu-guest-agent` is active.

`tests/contract/playbook.yml` verifies these conditions independently of either
downstream repository.
