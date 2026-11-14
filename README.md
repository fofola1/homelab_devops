# Homelab DevOps Stack

Terraform provisions a Debian 12 cloud template and a Docker VM on Proxmox, Ansible installs Docker Engine on the VM, and GitHub Actions deploys the compose stack in `docker/`. The sample stack currently contains a single nginx service exposed on port `8080`; add your own services to `docker/compose.yml`.

## Repository layout

| Path | Purpose |
| --- | --- |
| `.github/workflows/` | CI validation and the CD deployment pipeline. |
| `terraform/` | Proxmox provider, template profile, VM definition. |
| `ansible/` | Playbooks and inventory that configure the Proxmox host and the Docker VM. |
| `docker/` | Compose stack that is copied to the VM. |
| `scripts/` | Terraform-state, known-hosts, and Proxmox setup helpers. |
| `docs/deployment.md` | Setup, state, networking, and troubleshooting details. |
| `report-proxmox-state.conf.example` | Template for the local setup configuration. |

## How the pipelines work

- **CI - Validate** runs on pushes and pull requests to `main` and `dev` and checks Terraform formatting/validation, Ansible lint, compose file validity, the repository layout, and shell scripts with shellcheck.
- **CD - Deploy to Proxmox** runs on pushes to `main` or manually with `workflow_dispatch`. The `force_deploy` input deploys every stage even when change detection finds nothing. The default development branch is `dev`, so day-to-day deployments are started manually from it.

The CD pipeline detects changes and then runs five deployment stages: Ansible host, Terraform plan, Terraform apply, Ansible, and the compose deployment. Each deployment stage joins the Tailscale network with the tagged runner identity. The Proxmox node is used as an SSH jump host for the Docker VM, so the VM never needs to be reachable from the public internet.

## ZFS pool

The **Run Ansible (Host)** stage runs before Terraform and creates the ZFS pool on the Proxmox host. The pool name is fixed by the playbook (`tank`). It is created from the whole disks listed in the repository variable `ZFS_POOL_DRIVES` (comma-separated device paths) with the RAID level from `ZFS_POOL_RAID_LEVEL` (default `raidz1`).

The stage runs when change detection marks the `ansible/` or `terraform/` paths, or when `force_deploy` is enabled. Terraform then plans the Docker VM disk on the new pool.

Publish the selected drives and the RAID level as repository variables before the first deployment:

```bash
gh variable set ZFS_POOL_DRIVES --repo fofola1/homelab_devops --body "/dev/disk/by-id/scsi-SATA_..."
gh variable set ZFS_POOL_RAID_LEVEL --repo fofola1/homelab_devops --body "raidz1"
```

The pool creation is idempotent: the Ansible play checks `zpool status` first and only runs `zpool create` when the pool does not exist yet.

## First-time setup

Prerequisites: a Proxmox host reachable over SSH, an authenticated `gh` CLI, and a Tailscale OAuth client that can create `tag:proxmox-ci` nodes.

```bash
cp report-proxmox-state.conf.example report-proxmox-state.conf
./prepare-proxmox.sh
```

The setup script configures the Proxmox host, creates the API token, authorizes the deployment SSH key for `root`, and uploads the repository variables and secrets with `gh`. `report-proxmox-state.conf` is gitignored because it can contain the Tailscale OAuth secret; never commit it. See [`docs/deployment.md`](docs/deployment.md) for the full walkthrough and recovery steps.

## Configuration

The interactive setup writes these repository variables from `report-proxmox-state.conf`:

| Variable | Description |
| --- | --- |
| `TS_PROXMOX_HOSTNAME` | Proxmox host address over Tailscale. |
| `PROXMOX_NODE` | Proxmox node name. |
| `DOCKER_VM_HOST_IP` | Static IPv4 address for the Docker VM. |
| `DOCKER_VM_ID` | VM ID for the Docker VM. |
| `DOCKER_VM_DATASTORE` | Storage for the VM disk and cloud-init drive. |
| `DOCKER_VM_IMAGE_DATASTORE` | Storage that accepts the `import` content type for cloud images. |
| `DOCKER_VM_IPV4_CIDR` | Prefix length for the VM address. |
| `DOCKER_VM_IPV4_GATEWAY` | LAN gateway; also used as the VM's DNS server. |
| `DOCKER_VM_DEPLOY_PATH` | Directory on the VM for the compose stack. |
| `DOCKER_VM_DEPLOY_USER` | User created by cloud-init for SSH and Ansible. |
| `ZFS_POOL_DRIVES` | Whole disk devices for the ZFS pool, comma-separated (for example `/dev/disk/by-id/scsi-SATA_...`). |
| `ZFS_POOL_RAID_LEVEL` | RAID level for the ZFS pool, for example `raidz1`. |

Optionally set `PROXMOX_HOST_KEY_FINGERPRINT` manually to pin the Proxmox host key (see [`docs/deployment.md`](docs/deployment.md)).

It also creates the secrets `PROXMOX_SSH_KEY`, `PROXMOX_KNOWN_HOSTS`, `PVE_API_TOKEN`, `PVE_API_TOKEN_ID`, `PVE_API_TOKEN_SECRET`, `TS_OAUTH_CLIENT_ID`, and `TS_OAUTH_SECRET`.

## VM templates

The first CD run downloads the Debian 12 cloud image, uploads it to Proxmox, and creates a reusable template through Terraform. The Docker VM is then cloned from that managed template, so a clean Proxmox installation does not require a pre-existing template.

Template profiles live in `terraform/templates/` and are selected with `-var-file` in the Terraform plan and apply jobs. To use another image, add a `.tfvars` file with the `template` object and update both `terraform plan` invocations in `.github/workflows/deploy.yml`. The `Upload Debian image to Proxmox` step in the same workflow also contains a copy of the image URL, file name, and checksum; keep those values in sync with the profile. VM address, ID, storage, gateway, and deployment settings remain in `report-proxmox-state.conf`.

The Debian image is not stored in the Git repository. A cloud image is a large binary artifact, and GitHub rejects normal files above 100 MB. Git LFS or a GitHub Release asset could store it, but both add another artifact dependency and the release asset would still need to be uploaded before the first deployment. The template profile uses a verified direct Debian mirror URL instead. Terraform imports it as a `raw` disk, which is required by LVM-thin storage.

## Terraform state

State is stored on the dedicated `terraform-state` branch and is restored at the start of the plan and apply jobs. Do not delete the branch: Terraform would no longer know about the existing template and VM, and the next apply would try to create them again.

The state contains only infrastructure attributes and the cloud-init public key, not the Proxmox API token. Plan files are not uploaded as artifacts because this repository is public and plans contain sensitive values; the apply job regenerates the plan locally.

## Local validation

```bash
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform init -backend=false && terraform -chdir=terraform validate
ansible-lint ansible/
docker compose -f docker/compose.yml config --quiet
bash scripts/validate-layout.sh
shellcheck scripts/*.sh prepare-proxmox.sh prepare-proxmox-remote.sh
```

## Troubleshooting

- **Host key verification failed:** the workflow seeds `known_hosts` from `PROXMOX_KNOWN_HOSTS` and refreshes it with `ssh-keyscan`. Re-run the setup if the secret belongs to an old host.
- **`Failed to update apt cache`:** the VM has a static address, so Terraform and Ansible configure DNS explicitly. Check the network diagnostics the Ansible job prints and verify `DOCKER_VM_IPV4_GATEWAY`.
- **VM already exists:** restore the `terraform-state` branch, or import the existing VM, before applying again.

More recovery notes are in [`docs/deployment.md`](docs/deployment.md).
