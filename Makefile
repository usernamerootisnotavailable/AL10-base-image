SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

include versions.env

# Allow site-specific overrides from the environment or the command line.
PVE_HOST ?=
PVE_SSH_PORT ?= 22
PVE_SSH_OPTS ?=
PVE_STORAGE ?= ZFS-ZR2-Enc
PVE_BRIDGE ?= vmbr0
TEMPLATE_VMID ?= 9000
TEMPLATE_CORES ?= 2
TEMPLATE_MEMORY ?= 2048
TEMPLATE_CPU ?= x86-64-v2-AES
TEMPLATE_EFI_TYPE ?= 4m
TEMPLATE_SECURE_BOOT ?= 0
TEST_VMID ?= 9100
TEST_SSH_PORT ?= 2222
TEST_KNOWN_HOSTS ?= .build/test/known_hosts
DIST_DIR ?= dist
BUILD_DIR ?= .build
PACKER_BIN ?= packer
ALLOW_TCG ?= 0
KEEP_TEST_VM ?= 0
IMAGE_BASENAME := almalinux-$(IMAGE_VERSION)-$(IMAGE_ARCH).qcow2
IMAGE_FILE ?= $(DIST_DIR)/$(IMAGE_BASENAME)

export ALMA_MAJOR ALMA_RELEASE ALMA_IMAGE_DATE ALMA_CLOUD_FS
export ALMA_CLOUD_IMAGE_NAME ALMA_CLOUD_IMAGE_URL ALMA_CLOUD_IMAGE_SHA256
export IMAGE_REVISION IMAGE_VERSION IMAGE_NAME IMAGE_ARCH BUILD_DISK_SIZE
export IMAGE_BASENAME IMAGE_FILE
export PVE_HOST PVE_SSH_PORT PVE_SSH_OPTS PVE_STORAGE PVE_BRIDGE TEMPLATE_VMID
export TEMPLATE_CORES TEMPLATE_MEMORY TEMPLATE_CPU TEMPLATE_EFI_TYPE
export TEMPLATE_SECURE_BOOT
export TEST_VMID TEST_SSH_PORT TEST_KNOWN_HOSTS DIST_DIR BUILD_DIR PACKER_BIN
export ALLOW_TCG KEEP_TEST_VM

.PHONY: help deps-check fmt validate build test test-qemu contract pve-template pve-smoke lint clean

help:
	@printf '%s\n' \
	  'AL10 base image' \
	  '' \
	  '  make deps-check      Check local build dependencies' \
	  '  make build           Build the qcow2 into dist/' \
	  '  make test-qemu       Boot the image and verify first-boot behavior' \
	  '  make test            Alias for test-qemu' \
	  '  make pve-template    Import the image as a Proxmox template' \
	  '  make pve-smoke       Clone the template and verify it on Proxmox' \
	  '  make contract        Run the Ansible contract against TEST_HOST' \
	  '  make lint            Run repository linters' \
	  '  make clean           Remove build outputs' \
	  '' \
	  'Useful variables:' \
	  '  PVE_HOST=root@pve PVE_STORAGE=ZFS-ZR2-Enc make pve-template' \
	  '  PVE_HOST=root@pve TEMPLATE_VMID=9000 make pve-smoke' \
	  '  TEST_HOST=192.0.2.10 TEST_SSH_KEY=... make contract' \
	  '' \
	  'Image pins live in versions.env; Proxmox defaults are Make variables.'

deps-check:
	scripts/deps-check.sh

fmt:
	$(PACKER_BIN) fmt -recursive packer

validate:
	scripts/packer-validate.sh

build: deps-check
	scripts/build.sh

test-qemu:
	scripts/test-qemu.sh

test: test-qemu

contract:
	@test -n "$(TEST_HOST)" || { echo 'Set TEST_HOST to the guest address.' >&2; exit 1; }
	@test -n "$(TEST_SSH_KEY)" || { echo 'Set TEST_SSH_KEY to the private key.' >&2; exit 1; }
	ansible-playbook \
	  -i '$(TEST_HOST),' \
	  -u ansible \
	  --private-key '$(TEST_SSH_KEY)' \
	  -e 'ansible_ssh_common_args=-o StrictHostKeyChecking=yes -o UserKnownHostsFile=$(TEST_KNOWN_HOSTS)' \
	  tests/contract/playbook.yml

pve-template:
	scripts/pve-template.sh

pve-smoke:
	scripts/pve-smoke.sh

lint:
	scripts/lint.sh

clean:
	rm -rf '$(BUILD_DIR)' '$(DIST_DIR)'
