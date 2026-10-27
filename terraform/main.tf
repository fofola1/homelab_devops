terraform {
  required_version = ">= 1.6.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.84.0"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_api_url
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_tls_insecure
}

resource "proxmox_virtual_environment_vm" "template" {
  name      = var.template.name
  node_name = var.proxmox_node
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
    datastore_id = var.vm_datastore
    file_format  = "qcow2"
    import_from  = "${var.vm_image_datastore}:import/${var.template.image_file_name}"
    interface    = "scsi0"
  }

  network_device {
    bridge = var.vm_network_bridge
  }

  initialization {
    datastore_id = var.vm_datastore
  }

  serial_device {
    device = "socket"
  }
}

resource "proxmox_virtual_environment_vm" "docker" {
  name      = var.vm_name
  node_name = var.proxmox_node
  vm_id     = var.vm_id

  clone {
    datastore_id = var.vm_datastore
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
    datastore_id = var.vm_datastore
    interface    = "scsi0"
    size         = var.vm_disk_gb
  }

  network_device {
    bridge = var.vm_network_bridge
  }

  initialization {
    datastore_id = var.vm_datastore

    ip_config {
      ipv4 {
        address = "${var.vm_ipv4_address}/${var.vm_ipv4_cidr}"
        gateway = var.vm_ipv4_gateway
      }
    }

    user_account {
      username = var.docker_user
      keys     = [var.ssh_public_key]
    }
  }
}