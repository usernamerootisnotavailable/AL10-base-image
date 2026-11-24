# Agent and Contributor Rules

This is the short, enforceable rulebook for every change in this repository.
Read it before editing any file.

## Required reading order

1. `README.md`
2. `AGENTS.md` (this file)
3. `docs/ARCHITECTURE.md`
4. `docs/IMAGE-CONTRACT.md`
5. `docs/BUILD.md`
6. `docs/PROXMOX.md`
7. `docs/TESTING.md`
8. `docs/OPERATIONS.md`

If a rule is unclear, stop and ask. Do not invent a new convention silently.

## Hard rules

### Platform and scope

- The image targets AlmaLinux 10 x86_64 only.
- This repository builds a generic base image. It must not install Technitium,
  storage services, Podman, PostgreSQL, MariaDB, Garage, Elasticsearch, NGINX,
  Certbot, or application configuration.
- Application installation, network configuration, service hardening, secrets,
  and backups belong in the downstream repositories.
- Keep the image bootable with both UEFI/OVMF and BIOS firmware. The Proxmox
  template uses UEFI with Secure Boot disabled unless a reviewed change says
  otherwise.

### Pinning and provenance

- Pin the AlmaLinux cloud image by exact filename, URL, and SHA256 in
  `versions.env`. Never use a `latest` URL.
- Pin Packer, the QEMU plugin, GitHub Actions, and lint tools to explicit
  versions.
- Record the base image checksum, build date, git commit, package list, and
  artifact checksum in the build manifest.
- Do not silently upgrade a component as part of an unrelated change.

### Access contract

- Keep the `ansible` user with a locked password, `/bin/bash`, and NOPASSWD
  sudo. Both downstream repositories depend on it.
- SSH must remain public-key only. Root login and password authentication must
  stay disabled.
- cloud-init must default to the `ansible` user and support Proxmox's NoCloud
  seed.
- Do not bake an SSH authorized key into the image. Proxmox cloud-init supplies
  the per-VM key.
- Do not remove `qemu-guest-agent`, `cloud-init`, `cloud-utils-growpart`,
  `python3`, `python3-dnf`, `sudo`, `openssh-server`, `firewalld`, or `chrony`.

### Security

- SELinux stays enforcing.
- firewalld stays enabled. The image may allow only the distribution default
  SSH access; downstream roles own the final exposure rules.
- Never open HTTP, HTTPS, DNS, DHCP, database, or application ports in the base
  image.
- Never put secrets, private keys, tokens, or real production addresses in the
  repository, cloud-init files, logs, or commit messages.
- Build and test keys are generated at runtime and removed before the image is
  finalized.
- Never use `StrictHostKeyChecking=no` or disable host key verification in a
  committed script. Test scripts use a temporary `known_hosts`.
- Do not disable GPG signature checks for packages.
- Do not commit a Proxmox API token or password.

### First-boot cleanliness

The finalized image must not contain:

- an SSH host private key
- a build or test `authorized_keys` entry
- a populated `/etc/machine-id`
- a hostname, machine-info, or NetworkManager connection profile from the build
- cloud-init instance data or seed state
- package cache, DNF history, shell history, or build logs
- a password for the `ansible` user

Any change to cleanup or cloud-init must be tested from a clean first boot, not
only by provisioning the running build VM.

### Proxmox safety

- The import script must verify the image checksum before importing.
- The import script must refuse to overwrite an existing VMID.
- The smoke test must never destroy the template. It may destroy only the test
  VM whose name starts with `al10-smoke-`.
- `ZFS-ZR2-Enc` is an example storage ID. Validate that the storage exists
  before any import; fail clearly if it does not.
- Do not add Proxmox credentials to CI. Import and smoke tests run where the
  Proxmox network is reachable.

### Testing and quality

- Run `make lint`, `make build`, and `make test-qemu` for any image change.
- Run `make pve-smoke` for changes to the import script, template settings, or
  Proxmox-specific behavior.
- Do not report a test as passed unless it actually ran.
- The second downstream Ansible run must be idempotent; this image must not
  prevent that.
- Use fully qualified module names in Ansible playbooks.
- Every shell script must pass ShellCheck. Every YAML file must pass yamllint.
- Every markdown file must pass markdownlint.
- Update the documentation, manifest, and version in the same change.

### Repository hygiene

- Do not commit `dist/`, `.build/`, qcow2 images, ISO files, keys, logs, or
  caches.
- Do not commit generated GitHub Actions artifacts.
- Do not use `extra_vars` for normal image configuration.
- Do not claim compatibility with a distribution, firmware mode, or Proxmox
  version that has not been tested.

## Definition of done

A change is complete only when:

- The image still meets `docs/IMAGE-CONTRACT.md`.
- The base image and all tools remain pinned.
- The first-boot test passes and the image has no build credentials or
  identity artifacts.
- The Proxmox template still imports and the smoke test passes.
- No application configuration or secret entered this repository.
- The version and manifest were updated if the image contents changed.
- The documentation matches the actual behavior.
