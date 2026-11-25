# Proxmox

## Prerequisites

- A Proxmox VE node or cluster.
- The target storage must exist before import. The default is
  `ZFS-ZR2-Enc`, which is a valid PVE storage ID but is **not** created by this
  repository.
- SSH access from the operator machine to the Proxmox node, with a user allowed
  to run `sudo -n qm` and `sudo -n pvesm`. Set `PVE_SSH_PORT` if SSH is not on
  port 22. `PVE_SSH_OPTS` can carry extra options, such as
  `-i /path/to/key` or `-o StrictHostKeyChecking=yes`.
- A built qcow2 in `dist/`, or the GitHub Actions artifact downloaded and
  unpacked.

Check the storage:

```bash
pvesm status
```

If `ZFS-ZR2-Enc` is not listed, create the ZFS pool and add it as a Proxmox
storage first, or override `PVE_STORAGE` with an existing storage ID.

The storage ID rules allow letters, digits, dots, underscores, and hyphens. It
must start with a letter and end with a letter or digit. `ZFS-ZR2-Enc` satisfies
those rules; the underlying ZFS pool name is a separate choice.

## Template settings

| Setting | Value |
|---|---|
| VMID | `9000` |
| Name | `al10-base-<image-version>` |
| Firmware | OVMF/UEFI, Secure Boot off |
| Machine | q35 |
| SCSI controller | `virtio-scsi-single` |
| Disk | 16G, raw volume, discard and iothread enabled |
| CPU | `x86-64-v2-AES` by default; override with `TEMPLATE_CPU` (for example `host` on a homogeneous cluster) |
| vCPU / RAM | 2 / 2048 MiB |
| Network | virtio on `vmbr0` |
| Guest agent | Enabled |
| Cloud-init | IDE drive, `ciuser=ansible`, `ipconfig0 ip=dhcp` |
| Boot | `scsi0` |
| Tags | `almalinux;10;base;golden` |

The template does not contain an SSH key. Keys are injected per clone.

## Import the template

### From a workstation with SSH access

```bash
PVE_HOST=root@pve.example \
PVE_STORAGE=ZFS-ZR2-Enc \
TEMPLATE_VMID=9000 \
make pve-template
```

The script copies the image and checksum to `/var/tmp`, runs the import on the
node with `sudo -n`, and removes the remote temporary directory on success.

### On the Proxmox node

Copy the image and its checksum to the node, then:

```bash
sudo IMAGE_FILE=/var/tmp/almalinux-10.3-20261116.0-r1-x86_64.qcow2 \
  PVE_STORAGE=ZFS-ZR2-Enc \
  TEMPLATE_VMID=9000 \
  ./scripts/pve-template.sh
```

The script refuses to overwrite an existing VMID. Choose a new VMID for every
new image version. If a disk import or later step fails, the partially created
VM is intentionally left in place for inspection; remove it with
`qm destroy <vmid> --purge` after collecting the error.

## Clone a VM

### DHCP

```bash
qm clone 9000 201 --name technitium01 --full
qm set 201 --sshkeys ~/.ssh/ansible.pub
qm start 201
```

### Static address

```bash
qm clone 9000 201 --name technitium01 --full
qm set 201 \
  --ipconfig0 ip=10.20.0.5/24,gw=10.20.0.1 \
  --nameserver 1.1.1.1 \
  --sshkeys ~/.ssh/ansible.pub
qm start 201
```

Set `--nameserver` to a resolver that is reachable during the first Ansible
run. For the Technitium host, do not use the Technitium VM's own future address
before Technitium is installed and running.

If the VM needs more disk, resize it before or after startup, then let cloud-init
grow the root filesystem on first boot:

```bash
qm resize 201 scsi0 64G
```

The image's root filesystem grows to fill the new disk on first boot. If the VM
has already booted once, grow the partition and filesystem manually or reboot
after resizing.

## Cloud-init behavior

The template uses Proxmox's cloud-init drive with:

- `ciuser=ansible`
- `ipconfig0 ip=dhcp`
- no SSH keys baked in
- no static address baked in

At clone time, Proxmox writes the selected user, key, hostname, and network
configuration into the cloud-init drive. The guest image accepts NoCloud and
ConfigDrive seeds and regenerates SSH host keys and machine-id.

The `ansible` account already exists in the image with passwordless sudo, so
Proxmox only needs to inject the key and optional network settings.

## UEFI and Secure Boot

The template uses OVMF. Secure Boot is disabled by setting
`pre-enrolled-keys=0`. This avoids a first-build dependency on Secure Boot
variables while preserving the UEFI boot path. The image includes the removable
ESP fallback `/EFI/BOOT/BOOTX64.EFI`, so a fresh OVMF NVRAM store does not need
a manually created boot entry.

To enable Secure Boot later, create a new template with
`TEMPLATE_SECURE_BOOT=1` and test the downstream stack. AlmaLinux supports
Secure Boot, but changing firmware policy is a reviewed image change.

## Proxmox firewall

The template does not enable the Proxmox-level firewall. Guest firewalld is
enabled with only the default SSH allowance. Downstream repositories replace
that allowance with source CIDRs.

If the Proxmox firewall is enabled at the datacenter or VM level, allow the
guest agent and the intended SSH sources; otherwise the smoke test and Ansible
will fail.

## Smoke test

```bash
PVE_HOST=root@pve.example \
TEMPLATE_VMID=9000 \
TEST_VMID=9100 \
make pve-smoke
```

The test:

- clones the template
- injects an ephemeral SSH key
- starts the clone and waits for the guest agent
- discovers the guest IPv4 address through the agent
- verifies SSH, sudo, cloud-init, SELinux, firewalld, Python/dnf, and cleanup
- destroys the test VM

Set `KEEP_TEST_VM=1` to inspect the clone. The script never destroys the
template.

If the guest is not reachable from the machine running the test, run the test
from a host on the same network as the VM.

Optional variables:

| Variable | Default | Purpose |
|---|---|---|
| `TEST_IP` | auto-discovered | Skip agent IP discovery |
| `TEST_IPCONFIG` | `ip=dhcp` | Set a static cloud-init address |
| `TEST_NAMESERVER` | unset | Set a static resolver |
| `PVE_TEST_SSH_PORT` | `22` | Guest SSH port |
| `TEST_DISK_SIZE` | `20G` | Resize the clone before boot to test cloud-init growpart |
| `RUN_CONTRACT` | `0` | Run the Ansible contract after the guest checks |
| `KEEP_TEST_VM` | `0` | Leave the test VM running |

## Downstream Ansible

Use the VM address and the `ansible` key in the downstream inventory:

```yaml
all:
  children:
    dns:
      hosts:
        dns01:
          ansible_host: 10.20.0.5
          ansible_user: ansible
```

A first connectivity check:

```bash
ansible -i inventories/prod/hosts.yml dns -m ansible.builtin.ping
```

Then apply the downstream `site.yml`. The downstream `common` role will install
its package set, harden SSH, and configure firewalld. The image deliberately
does not pre-apply those rules so the downstream repositories remain the source
of truth.

## Rollback

Templates are versioned and never overwritten. Keep the previous template until
the new image passes the QEMU test, the Proxmox smoke test, and a downstream
deployment. To roll back, clone the previous template and point the inventory at
the new VM.

Do not delete a template while clones depend on it for a documented recovery
path.
