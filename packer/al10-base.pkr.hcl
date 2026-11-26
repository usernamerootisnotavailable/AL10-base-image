packer {
  required_version = ">= 1.11.0"

  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "1.1.8"
    }
  }
}

variable "base_image_path" {
  type        = string
  description = "Local path to the pinned AlmaLinux GenericCloud qcow2."
}

variable "base_image_checksum" {
  type        = string
  description = "Packer checksum for the bootable work image."
}

variable "base_image_sha256" {
  type        = string
  description = "Bare SHA256 of the base image, recorded in the guest manifest."
}

variable "base_image_url" {
  type        = string
  description = "Upstream URL of the base image, recorded in the guest manifest."
}

variable "image_version" {
  type        = string
  description = "Image version, for example 10.3-20261116.0-r1."
}

variable "build_git_sha" {
  type        = string
  description = "Git commit that produced the image."
}

variable "build_date" {
  type        = string
  description = "UTC build timestamp."
}

variable "disk_size" {
  type        = string
  default     = "16G"
  description = "Virtual disk size for the image and template."
}

variable "memory" {
  type        = number
  default     = 2048
  description = "Build VM memory in MiB."
}

variable "cpus" {
  type        = number
  default     = 2
  description = "Build VM vCPU count."
}

variable "ssh_public_key" {
  type        = string
  description = "Ephemeral build public key injected by cloud-init."
}

variable "ssh_private_key_file" {
  type        = string
  sensitive   = true
  description = "Ephemeral build private key used by Packer."
}

variable "output_directory" {
  type        = string
  description = "Packer output directory."
}

variable "console_log_path" {
  type        = string
  description = "Guest serial console log path."
}

variable "build_info_file" {
  type        = string
  description = "Local file with non-secret build metadata uploaded to the guest."
}

variable "build_hostname" {
  type        = string
  default     = "al10-base-build"
  description = "Hostname used only during the build."
}

variable "accelerator" {
  type        = string
  default     = "kvm"
  description = "QEMU accelerator: kvm or tcg."
}

variable "cpu_model" {
  type        = string
  default     = "host"
  description = "QEMU CPU model. Use max with TCG."
}

variable "headless" {
  type        = bool
  default     = true
  description = "Run QEMU without a display."
}

locals {
  provision_dir = "${path.root}/../scripts/provision"
  instance_id   = "al10-base-${var.image_version}"

  provision_env = [
    "IMAGE_VERSION=${var.image_version}",
    "ALMA_CLOUD_IMAGE_URL=${var.base_image_url}",
    "ALMA_CLOUD_IMAGE_SHA256=${var.base_image_sha256}",
    "BUILD_DATE=${var.build_date}",
    "BUILD_GIT_SHA=${var.build_git_sha}",
    "BUILD_HOSTNAME=${var.build_hostname}",
  ]
}

source "qemu" "al10" {
  iso_url      = var.base_image_path
  iso_checksum = var.base_image_checksum
  disk_image   = true
  accelerator  = var.accelerator
  cpu_model    = var.cpu_model
  machine_type = "q35"
  memory       = var.memory
  cpus         = var.cpus
  disk_size    = var.disk_size
  # Use virtio-blk for the BIOS provisioning boot. SeaBIOS and virtio-scsi
  # have an unreliable boot path; the final Proxmox disk controller is
  # independent of this build-time choice.
  disk_interface   = "virtio"
  disk_cache       = "writeback"
  disk_discard     = "unmap"
  disk_compression = true
  format           = "qcow2"
  net_device       = "virtio-net"
  headless         = var.headless
  output_directory = var.output_directory
  vm_name          = "almalinux-10-base.qcow2"

  # Provision under BIOS/SeaBIOS. The configure step installs a removable UEFI
  # fallback loader ($ESP/EFI/BOOT/BOOTX64.EFI) for Proxmox OVMF and the
  # post-build UEFI first-boot test.

  ssh_username            = "ansible"
  ssh_private_key_file    = var.ssh_private_key_file
  ssh_timeout             = "10m"
  ssh_handshake_attempts  = 60
  shutdown_command        = "sudo systemctl poweroff"
  shutdown_timeout        = "10m"
  pause_before_connecting = "5s"

  cd_label = "cidata"
  cd_content = {
    "meta-data" = templatefile("cloud-init/meta-data.pkrtpl", {
      instance_id = local.instance_id
      hostname    = var.build_hostname
    })
    "user-data" = templatefile("cloud-init/user-data.pkrtpl", {
      hostname       = var.build_hostname
      ssh_public_key = var.ssh_public_key
    })
  }

  qemuargs = [
    ["-boot", "order=c"],
    ["-serial", "file:${var.console_log_path}"],
    ["-device", "virtio-serial-pci"],
    ["-chardev", "null,id=qga0"],
    ["-device", "virtserialport,chardev=qga0,name=org.qemu.guest_agent.0"],
  ]
}

build {
  sources = ["source.qemu.al10"]

  provisioner "file" {
    source      = var.build_info_file
    destination = "/tmp/al10-base-build-info"
  }

  provisioner "shell" {
    execute_command  = "sudo -E bash -euxo pipefail '{{.Path}}'"
    environment_vars = local.provision_env
    timeout          = "45m"
    scripts = [
      "${local.provision_dir}/10-update.sh",
      "${local.provision_dir}/20-install.sh",
    ]
  }

  provisioner "shell" {
    execute_command  = "sudo -E bash -euxo pipefail '{{.Path}}'"
    environment_vars = local.provision_env
    timeout          = "30m"
    scripts = [
      "${local.provision_dir}/40-configure.sh",
      "${local.provision_dir}/50-manifest.sh",
      "${local.provision_dir}/90-cleanup.sh",
    ]
  }
}
