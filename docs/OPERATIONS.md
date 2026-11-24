# Operations

## Versioning

The image version is:

```text
<AlmaLinux release>-<cloud image date>-r<revision>
```

For example:

```text
10.3-20261116.0-r1
```

The Proxmox template name is `al10-base-<image version>`. The template VMID is
independent and must be unique in the cluster; never overwrite an existing VMID.

## Rebuild cadence

Rebuild when:

- AlmaLinux publishes a new GenericCloud image
- a baseline package or image-contract change is merged
- a security update should be baked into new clones
- the downstream repositories need a new baseline

A monthly rebuild is a reasonable default. Running hosts are not upgraded by
this repository; the downstream `update-prod` playbook owns in-place updates.

## Base image update procedure

1. Find the new AlmaLinux GenericCloud x86_64 qcow2 and SHA256.
2. Update `versions.env`:
   - `ALMA_RELEASE`
   - `ALMA_IMAGE_DATE`
   - `ALMA_CLOUD_IMAGE_NAME`
   - `ALMA_CLOUD_IMAGE_URL`
   - `ALMA_CLOUD_IMAGE_SHA256`
   - `IMAGE_REVISION` and `IMAGE_VERSION`
3. Run `make lint build test-qemu`.
4. Download or use the CI artifact.
5. Import a new template with a new VMID:

   ```bash
   PVE_HOST=root@pve.example \
   PVE_STORAGE=ZFS-ZR2-Enc \
   TEMPLATE_VMID=9001 \
   make pve-template
   ```

6. Run `PVE_HOST=root@pve.example make pve-smoke TEMPLATE_VMID=9001 TEST_VMID=9101`.
7. Deploy a downstream test clone and run its verification.
8. Keep the previous template for rollback.
9. After the acceptance window, retire the old template.

## Template lifecycle

Keep at least one previous template. Clones are independent full copies; a
template is only a source. Do not change a template in place after it has been
used for production. Create a new version.

Suggested lifecycle:

| State | Action |
|---|---|
| Candidate | New template created with a new VMID |
| Validated | QEMU test, Proxmox smoke test, and downstream acceptance passed |
| Current | New clones use this template |
| Previous | Kept for rollback |
| Retired | No clones depend on it; remove after the retention window |

## Rollback

1. Identify the previous template VMID and name.
2. Clone it with a new VMID.
3. Set the intended cloud-init address and inject the key.
4. Start the clone and run the downstream verification.
5. Point the inventory at the replacement VM.

The image itself does not mutate a running host. Rollback is a new clone, not an
in-place downgrade.

## Security updates

- New base images include the latest AlmaLinux 10 updates at build time.
- A running VM is updated by the downstream repository's update playbook.
- SELinux and firewalld are never disabled to make an update pass.
- The image does not enable automatic updates; the downstream repositories own
  maintenance policy.

## Manifest and provenance

Each published artifact includes:

- `almalinux-<version>-x86_64.qcow2`
- `.sha256`
- `build-manifest.json`
- `package-list.txt`
- `image-info.txt`

Verify an artifact:

```bash
cd dist
sha256sum -c almalinux-10.3-20261116.0-r1-x86_64.qcow2.sha256
```

Verify the image marker inside a running clone:

```bash
cat /etc/al10-base-image
```

## Template removal

Before removing a template:

- Confirm no clones were created from it in the retention window.
- Confirm no runbook or rollback procedure still points to it.
- Confirm the replacement passed the downstream acceptance.

Removal is destructive and is not automated by this repository.

## Troubleshooting

| Problem | Check |
|---|---|
| Import fails: storage missing | `pvesm status`; create the ZFS storage or set `PVE_STORAGE` |
| Import fails: VMID exists | Choose a new `TEMPLATE_VMID`; never overwrite |
| Clone has no address | Proxmox cloud-init `ipconfig0`; guest agent; bridge; DHCP |
| SSH key rejected | Proxmox `ciuser=ansible`; key path; cloud-init drive present |
| First Ansible run cannot install packages | DNS/resolver, default route, outbound HTTPS |
| Downstream role fails on dnf | `python3-dnf`; `python3 -c 'import dnf'` |
| Firewall blocks Ansible after hardening | `common_firewall_allowed_ssh_cidrs` in downstream inventory |
| Guest agent not reporting | `systemctl status qemu-guest-agent`; Proxmox `agent: 1` |
| Disk did not grow | `cloud-utils-growpart`; clone was resized before/after boot; reboot |

## Out of scope

- Off-host backups
- Disaster recovery testing
- Proxmox cluster quorum and storage replication
- Public DNS and Let's Encrypt account management
- Application data migration
- High availability

Those are owned by the downstream repositories or the external platform.
