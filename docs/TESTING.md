# Testing

The image is tested at four layers. A change is not complete until the layers
that apply have actually run.

## 1. Static checks

```bash
make lint
```

Runs:

- `bash -n` and ShellCheck on every shell script
- `packer fmt -check`
- `packer validate`
- yamllint
- markdownlint
- gitleaks, when installed

The CI lint workflow installs pinned versions of the tools and runs the same
command.

## 2. QEMU build and first-boot test

```bash
make build
make test-qemu
```

The Packer build itself proves that the image boots, accepts an SSH connection,
can install packages, can configure the guest, and can power off cleanly. The
post-build QEMU test proves the image can boot the newly installed kernel and
reboot persistently.

The first-boot test then boots the **artifact** with:

- a fresh 20G qcow2 overlay
- a new cloud-init seed and a new ephemeral SSH key
- UEFI/OVMF firmware

It verifies:

- cloud-init completes without errors
- the `ansible` user exists and has passwordless sudo
- password SSH authentication is rejected
- SSH policy disables root login and password authentication
- `sshd`, `firewalld`, `chronyd`, and `qemu-guest-agent` are enabled and active
- all cloud-init units are enabled
- SELinux is enforcing
- the firewalld default zone is `public` and only SSH is allowed
- Python is 3.12+ and `python3-dnf` imports
- `dnf makecache` succeeds
- baseline packages are present
- the root filesystem grew on the 20G overlay
- machine-id and SSH host keys were regenerated
- the build SSH key is absent and the default `almalinux` user is gone
- the image version marker and package manifest exist
- cloud-init's default user is `ansible`
- cloud-init injected the test key

The test then reboots the guest, requires a new boot ID, verifies that SSH host
keys did not change across the reboot, and repeats the contract checks.

Console output is written to `.build/test/console.log`. CI uploads it when the
test fails.

## 3. Proxmox clone smoke test

```bash
PVE_HOST=root@pve.example \
TEMPLATE_VMID=9000 \
TEST_VMID=9100 \
make pve-smoke
```

This requires a real Proxmox node and a template created by
`make pve-template`.

The test verifies:

- the template uses OVMF, an EFI disk, the guest agent, and a cloud-init drive
- a full clone is resized to 20G and boots under Proxmox
- the guest agent responds
- the guest receives an address and is reachable over SSH
- Proxmox cloud-init injects the `ansible` key
- the same in-guest contract as the QEMU test passes

The test VM is destroyed on success and on failure unless `KEEP_TEST_VM=1`.
Only VMs named `al10-smoke-*` are eligible for destruction; the template is
never a destruction target.

## 4. Ansible contract

On a running clone, with an inventory or ad hoc host:

```bash
TEST_HOST=10.20.0.5 \
TEST_SSH_KEY=~/.ssh/ansible \
TEST_KNOWN_HOSTS=~/.ssh/known_hosts \
make contract
```

Or directly:

```bash
ansible-playbook \
  -i 10.20.0.5, \
  -u ansible \
  --private-key ~/.ssh/ansible \
  tests/contract/playbook.yml
```

The playbook gathers facts, requires AlmaLinux 10 x86_64, runs with
`become: true`, exercises the DNF module, checks SELinux and service state, and
requires the image marker.

This is the closest automated proof that the downstream repositories can start.

## CI

The build workflow runs the Packer build and the QEMU first-boot test on a free
`ubuntu-24.04` GitHub-hosted runner. GitHub currently exposes `/dev/kvm` on
these runners, but treats nested virtualization as experimental. The workflow
fails clearly if KVM is unavailable instead of silently using slow emulation.

CI does not import into Proxmox and does not receive Proxmox credentials. Run the
Proxmox smoke test from a trusted machine.

The workflow emits GitHub check annotations for every failure, including a
sanitized tail of `build.log`, `test.log`, and the QEMU console logs, so a
public repository can show the relevant error without downloading the
authenticated Actions log archive. A successful build emits a public notice with
the image version and SHA256. The workflow also runs a real KVM preflight before
Packer starts.

## What is not tested here

- Real DHCP broadcast behavior and VLANs
- Real Let's Encrypt DNS-01 issuance
- Cloudflare API access
- Technitium, PostgreSQL, MariaDB, Garage, Elasticsearch, or NGINX
- Off-host backups and disaster recovery
- Secure Boot enabled
- BIOS firmware deployment (the image is unified, but the template is UEFI)
- Multi-NIC or multi-homed topologies

Those belong to the downstream repositories or a real-host acceptance test.

## Downstream acceptance

After a new image passes all layers above:

1. Clone a template for the Technitium VM.
2. Set the intended static address and a working upstream resolver.
3. Inject the `ansible` key.
4. Run the downstream repository's `make lint`, `make syntax`, and production
   check/deploy path.
5. Repeat for the storage VM.
6. Run the downstream verification playbooks and a second idempotence run.
7. Keep the old template until both deployments are accepted.
