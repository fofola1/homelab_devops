variable "proxmox_api_url" {
  type = string
}

variable "proxmox_api_token" {
  type      = string
  sensitive = true
}

variable "proxmox_tls_insecure" {
  type    = bool
  default = true
}

variable "proxmox_node" {
  type = string
}

variable "template" {
  type = object({
    name                     = string
    vm_id                    = number
    image_url                = string
    image_file_name          = string
    image_checksum           = optional(string)
    image_checksum_algorithm = optional(string)
  })
}

variable "vm_id" {
  type = number
}

variable "vm_name" {
  type    = string
  default = "docker-host"
}

variable "vm_cpu_cores" {
  type    = number
  default = 4
}

variable "vm_memory_mb" {
  type    = number
  default = 8192
}

variable "vm_disk_gb" {
  type    = number
  default = 64
}

variable "vm_datastore" {
  type = string
}

variable "vm_image_datastore" {
  type = string
}

variable "vm_network_bridge" {
  type    = string
  default = "vmbr0"
}

variable "vm_ipv4_address" {
  type = string
}

variable "vm_ipv4_cidr" {
  type = number
}

variable "vm_ipv4_gateway" {
  type = string
}

variable "docker_user" {
  type    = string
  default = "deploy"
}

variable "ssh_public_key" {
  type = string
}