terraform {
  required_version = ">= 1.6.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.84.0"
    }
  }

  backend "s3" {
    bucket = "tfstate"
    key    = "proxmox/terraform.tfstate"
    region = "auto"

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = true
    use_lockfile                = true
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_api_url
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_tls_insecure
}

locals {
  cfg = yamldecode(file("${path.module}/../config/infra.yaml"))

  proxmox_node       = local.cfg.proxmox.node
  vm_id              = local.cfg.cloud_storage.id
  vm_datastore       = local.cfg.cloud_storage.datastore
  vm_image_datastore = local.cfg.cloud_storage.image_datastore
  vm_ipv4_address    = local.cfg.cloud_storage.network.ip
  vm_ipv4_cidr       = local.cfg.cloud_storage.network.cidr
  vm_ipv4_gateway    = local.cfg.cloud_storage.network.gateway
  deploy_user        = local.cfg.access.deploy_user
}

resource "proxmox_virtual_environment_vm" "template" {
  name      = var.template.name
  node_name = local.proxmox_node
  vm_id     = var.template.vm_id
  started   = false
  template  = true

  cpu {
    cores = 2
  }

  memory {
    dedicated = 2048
  }

  disk {
    datastore_id = local.vm_datastore
    file_format  = "raw"
    import_from  = "${local.vm_image_datastore}:import/${var.template.image_file_name}"
    interface    = "scsi0"
  }

  network_device {
    bridge = var.vm_network_bridge
  }

  initialization {
    datastore_id = local.vm_datastore
  }

  serial_device {
    device = "socket"
  }
}

# One-time re-bootstrap: cloud-init must run again to unlock the deploy account.
resource "terraform_data" "cloud_storage_rebootstrap" {
  input = "2026-11-27-unlock-deploy-account"
}

resource "proxmox_virtual_environment_vm" "cloud_storage" {
  name      = var.vm_name
  node_name = local.proxmox_node
  vm_id     = local.vm_id

  lifecycle {
    replace_triggered_by = [terraform_data.cloud_storage_rebootstrap]
  }

  clone {
    datastore_id = local.vm_datastore
    vm_id        = proxmox_virtual_environment_vm.template.vm_id
    full         = true
  }

  cpu {
    cores = var.vm_cpu_cores
  }

  memory {
    dedicated = var.vm_memory_mb
  }

  disk {
    datastore_id = local.vm_datastore
    interface    = "scsi0"
    size         = var.vm_disk_gb
  }

  network_device {
    bridge = var.vm_network_bridge
  }

  initialization {
    datastore_id = local.vm_datastore

    dns {
      servers = [local.vm_ipv4_gateway]
    }

    ip_config {
      ipv4 {
        address = "${local.vm_ipv4_address}/${local.vm_ipv4_cidr}"
        gateway = local.vm_ipv4_gateway
      }
    }

    # Alpine's PAM-backed sshd rejects pubkey auth for accounts cloud-init leaves locked.
    user_account {
      username = local.deploy_user
      keys     = [var.vm_deploy_ssh_public_key]
      password = var.vm_deploy_password
    }
  }
}
