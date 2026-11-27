# onprem DevOps Stack

Terraform provisions a cloud image template and a cloud storage VM on Proxmox, Ansible installs Docker Engine on the VM, and GitHub Actions deploys the compose stack in `docker/`. The stack currently runs Immich for the photo library and FileBrowser Quantum as the file manager; add your own services to `docker/compose.yml`.

## Repository layout

| Path | Purpose |
| --- | --- |
| `.github/workflows/` | CI validation and the CD deployment pipeline. |
| `terraform/` | Proxmox provider, template profile, VM definition. |
| `ansible/` | Playbook and inventory that configure the Cloud Storage VM. |
| `docker/` | Compose stack that is copied to the VM. |
| `config/` | Committed infrastructure configuration and administrator public keys (Proxmox node, ZFS pool, Cloud Storage VM, access accounts). |
| `scripts/` | Terraform-state, known-hosts, and Proxmox setup helpers. |
| `docs/deployment.md` | Setup, state, networking, and troubleshooting details. |
| `report-proxmox-state.conf.example` | Template for the local setup configuration. |

## How the pipelines work

- **CI - Validate** runs on pushes and pull requests to `main` and `dev` and checks Terraform formatting/validation, Ansible lint, compose file validity, the repository layout, and shell scripts with shellcheck.
- **CD - Deploy to Proxmox** runs on pushes to `main` or manually with `workflow_dispatch`. The `force_deploy` input deploys every stage even when change detection finds nothing. The default development branch is `dev`, so day-to-day deployments are started manually from it.

The CD pipeline detects changes and then runs four deployment stages: Terraform plan, Terraform apply, Ansible, and the compose deployment. Each deployment stage joins the Tailscale network with the tagged runner identity. The Proxmox node is used as an SSH jump host for the Cloud Storage VM, so the VM never needs to be reachable from the public internet.

## Access model

SSH access is key-only and split by role. Root is reserved for console access.

| Account | Where | Access |
| --- | --- | --- |
| `root` | Proxmox host and VMs | Console/noVNC only; SSH root login is disabled. Keep the password offline. |
| `fofola` (from `access.admin_user`) | Proxmox host and VMs | Human administrator. Multiple public keys from `config/ssh/admin/`, full sudo. |
| `deployer` (from `access.deploy_user`) | Proxmox host | Automation. One key from `PROXMOX_DEPLOY_SSH_KEY`, no sudo, TCP forwarding to the VM only. |
| `deployer` (from `access.deploy_user`) | Cloud Storage VM | Automation. One key from `CLOUD_STORAGE_DEPLOY_SSH_KEY`, passwordless sudo and Docker group for provisioning. |

Administrator public keys are committed because they are not secrets. Private keys stay on your machines. The two automation keys are separate, so rotating one never affects the other or your own access.

## ZFS pool

The interactive setup (`prepare-proxmox.sh`) creates the ZFS pool on the Proxmox host. The pool name is fixed (`tank`). Its drives and RAID level come from the committed `config/infra.yaml` (`proxmox.zfs.drives` and `proxmox.zfs.raid_level`; use `"none"` for a single drive without redundancy).

The script lists the configured drives in the final confirmation prompt and checks that they exist on the host before changing anything, because the drives are wiped. Edit `config/infra.yaml` first if the selection is wrong.

Leave `proxmox.zfs.drives` empty (or remove the key) on a single-disk server where Proxmox VE and the data share the same disk; the setup then skips the pool.

Creation is idempotent: it checks `zpool status` first and only runs `zpool create` when the pool does not exist yet.

Growing the pool: add the new drive to the `drives` list in `config/infra.yaml` and rerun `./prepare-proxmox.sh`. The script detects an existing pool and, after the same confirmation, runs `zpool add -f tank <new-device>` for every configured drive that is not part of the pool yet, so the pool spans all the drives. No Ansible or CD step does this; the setup script is the only place that touches the pool.

CI no longer creates the pool. If the pool is missing later, rerun `./prepare-proxmox.sh` from a machine that can reach the host.

## First-time setup

Prerequisites: a Proxmox host reachable over SSH as root (password or existing key), an authenticated `gh` CLI, at least one administrator public key in `config/ssh/admin/`, and a Tailscale OAuth client that can create `tag:proxmox-ci` nodes.

```bash
cp report-proxmox-state.conf.example report-proxmox-state.conf
./prepare-proxmox.sh
```

The setup script creates the administrator and deployment users, installs the administrator keys, installs the deployment key, creates the API token, creates the ZFS pool, and uploads the repository variables and secrets with `gh`. It verifies the deployment login and then disables root SSH and password authentication. The root password is requested once; the SSH connection is reused for the rest of the run. `report-proxmox-state.conf` is gitignored because it can contain the Tailscale OAuth secret; never commit it. See [`docs/deployment.md`](docs/deployment.md) for the full walkthrough and recovery steps.

## Configuration

The Proxmox node, ZFS pool, Cloud Storage VM, and access accounts live in the committed [`config/infra.yaml`](config/infra.yaml):

```yaml
access:
  admin_user: "fofola"
  admin_authorized_keys_dir: "config/ssh/admin"
  deploy_user: "deployer"

proxmox:
  node: "nas"
  zfs:
    raid_level: "raidz1"
    drives:
      - "/dev/sdc"
      - "/dev/sdd"
      - "/dev/sde"

cloud_storage:
  bootstrap_user: "alpine"
  id: 120
  datastore: "local-lvm"
  image_datastore: "local"
  network:
    ip: "10.10.10.31"
    cidr: 24
    gateway: "10.10.10.1"
  deploy:
    path: "/opt/docker"
```

The interactive setup writes these repository variables from `report-proxmox-state.conf`:

| Variable | Description |
| --- | --- |
| `TS_PROXMOX_HOSTNAME` | Proxmox host address over Tailscale (fetched automatically during setup). |
| `PROXMOX_HOST_KEY_FINGERPRINT` | Pinned Proxmox host key fingerprint (fetched automatically during setup). |
| `TF_STATE_S3_URL` | S3 endpoint URL when the optional S3 state backend is used. |
| `TF_STATE_S3_NAME` | S3 bucket name when the optional S3 state backend is used (defaults to `tfstate`). |
| `TERRAFORM_STATE_TO_GIT` | Whether to mirror the Terraform state to the `terraform-state` branch; default `true`. |

It also creates the secrets `PROXMOX_DEPLOY_SSH_KEY`, `CLOUD_STORAGE_DEPLOY_SSH_KEY`, `PROXMOX_KNOWN_HOSTS`, `PVE_API_TOKEN`, `PVE_API_TOKEN_ID`, `PVE_API_TOKEN_SECRET`, `TS_OAUTH_CLIENT_ID`, and `TS_OAUTH_SECRET`. The optional `CLOUD_STORAGE_ROOT_PASSWORD_HASH` secret sets the VM root password for console break-glass.

The administrator public keys are committed under `config/ssh/admin/` (one or more `*.pub` files). They are public by design; private keys must never be committed.

When the optional S3 state backend is configured, it also creates the repository variable `TF_STATE_S3_URL`, the repository variable `TF_STATE_S3_NAME`, the secret `TF_STATE_S3_KEY_ID`, and the secret `TF_STATE_S3_KEY_SECRET`. The S3 values are requested by `./prepare-proxmox.sh` when the optional S3 setup is accepted.

## VM templates

The first CD run downloads the selected cloud image, uploads it to Proxmox, and creates a reusable template through Terraform. The cloud storage VM is then cloned from that managed template, so a clean Proxmox installation does not require a pre-existing template.

Template profiles live in `terraform/templates/` and each `.tfvars` file holds one `template` object with the image URL, file name, checksum, and Proxmox VM ID for that image. The profile used by the deployment is selected with the `cloud_storage.template` value in `config/infra.yaml` (default `alpine-324`), which holds the profile file name without the `.tfvars` suffix (for example `alpine-324`).

To add or switch a template:

1. Add `terraform/templates/<name>.tfvars` with the `template` object for the new image.
2. Set `cloud_storage.template` in `config/infra.yaml` to `<name>`.

The CD workflow resolves the selected profile, uploads its image, and plans and applies the VM from it, so adding or changing a template only ever touches the new profile file and the repository variable. VM address, ID, storage, gateway, and deployment settings remain in `config/infra.yaml`.

Changing the `cloud_storage.template` value in `config/infra.yaml` requires a manual workflow run (`workflow_dispatch`) to trigger a deployment.

The Alpine image is not stored in the Git repository. A cloud image is a large binary artifact, and GitHub rejects normal files above 100 MB. Git LFS or a GitHub Release asset could store it, but both add another artifact dependency and the release asset would still need to be uploaded before the first deployment. The template profile uses a verified direct mirror URL instead. Terraform imports it as a `raw` disk, which is required by LVM-thin storage.

## Cloud storage VM

The cloud storage VM is named `cloud-storage` and runs on the template selected via `config/infra.yaml` (`cloud_storage.template`). It gets the static address from `config/infra.yaml`. Cloud-init puts the VM deployment key on `cloud_storage.bootstrap_user` (the image's default user, which has passwordless `doas`); the CD pipeline uses it to create the `access.deploy_user` account, install `sudo`, and authorize the key. Ansible creates the `access.admin_user` account with the committed administrator keys, disables root and password SSH, and installs Docker Engine and the Compose plugin, loads the `virtiofs` kernel module, and mounts the shared storage from the ZFS pool:

- `/tank/immich` for the Immich library.
- `/tank/filebrowser` for the FileBrowser Quantum file manager.

The compose stack in `docker/compose.yml` starts Immich (port `2283`) and FileBrowser Quantum (port `8080`), both reading from those mounts.

When other VMs access the same pool through virtiofs later, keep an eye on file ownership: the same pool mounted from multiple VMs can end up with conflicting UIDs and cause permission errors.

## Rotating SSH keys

- **Administrator:** add a new `.pub` file to `config/ssh/admin/`, rerun `./prepare-proxmox.sh` to install it on the host, and rerun the Ansible stage to install it on the VM. Verify the new login, then remove the old file. Multiple keys are supported and the playbook keeps the VM authorized keys in sync with the directory.
- **Deployment:** generate a new key, authorize it for the deployment user, update the matching GitHub secret (`PROXMOX_DEPLOY_SSH_KEY` or `CLOUD_STORAGE_DEPLOY_SSH_KEY`), and remove the old key. The two targets are independent, so rotating one never locks you out of the other.
- **Recovery:** root SSH is disabled. Use the Proxmox console/noVNC with the root password, or the administrator account, to restore access.

## Terraform state

State is stored in the S3 backend configured in `terraform/main.tf` (Cloudflare R2) and is read and written by the Terraform plan and apply jobs during deployment.

The state is mirrored to the dedicated `terraform-state` git branch as well; uploading to that branch can be disabled with the `TERRAFORM_STATE_TO_GIT` repository variable. Do not delete the branch: Terraform would no longer know about the existing template and VM, and the next apply would try to create them again.

The state contains only infrastructure attributes, the cloud-init public key, and a masked placeholder for the bootstrap password derived from `CLOUD_STORAGE_DEPLOY_SSH_KEY` — not the Proxmox API token, the password itself, or any S3 credential. Plan files are not uploaded as artifacts because this repository is public and plans contain sensitive values; the apply job regenerates the plan locally.

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
- **Cannot SSH to the Proxmox host:** use the administrator account and the committed keys. Root SSH is intentionally disabled; use the console/noVNC with the root password for break-glass access.
- **Cannot SSH to the Cloud Storage VM:** use the administrator account or the deployment key from `CLOUD_STORAGE_DEPLOY_SSH_KEY`. The deployment user is `access.deploy_user`; `alpine` is only the temporary bootstrap account and is locked once Ansible runs. If bootstrap fails, check that `cloud_storage.bootstrap_user` matches the image user and that `apk add sudo` can reach the repositories.
- **Cloud-init reports `status: error`:** the CD pipeline waits for cloud-init but reports its status instead of failing; Ansible fixes DNS and packages itself and prints the detailed status. Check that output and verify `cloud_storage.network.gateway` in `config/infra.yaml` if packages still fail.
- **Failed to update the package cache:** the VM has a static address, so Terraform and Ansible configure DNS explicitly. Check the network diagnostics the Ansible job prints and verify the gateway from `cloud_storage.network.gateway` in `config/infra.yaml`.
- **VM already exists:** restore the `terraform-state` branch, or import the existing VM, before applying again.

More recovery notes are in [`docs/deployment.md`](docs/deployment.md).
