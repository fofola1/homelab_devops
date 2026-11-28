# Deployment

The deployment pipeline is defined in `.github/workflows/deploy.yml` and has four stages:

1. **Terraform Plan** validates the Terraform configuration against the current state.
2. **Terraform Apply** restores the state, applies the plan and saves the state.
3. **Run Ansible (Cloud Storage)** installs Docker Engine on the new VM, creates the administrator account, loads the virtiofs kernel module, and prepares the shared storage mounts and the deployment directory.
4. **Deploy Cloud Storage Workloads** copies `docker/` to the VM and runs `docker compose up`.

The Terraform stages resolve the template profile selected by the `cloud_storage.template` value in `config/infra.yaml` from `terraform/templates/` before planning and uploading the cloud image; the image URL, file name, checksum, and checksum algorithm therefore live only in the profile file.

## ZFS pool (host storage)

The interactive setup (`prepare-proxmox.sh`) creates the ZFS pool on the Proxmox host. The pool name is fixed (`tank`). Its drives and RAID level come from the committed `config/infra.yaml` (`proxmox.zfs.drives` and `proxmox.zfs.raid_level`; use `"none"` for a single drive without redundancy).

The script lists the configured drives in the final confirmation prompt and checks that they exist on the host before changing anything, because the drives are wiped. Edit `config/infra.yaml` first if the selection is wrong.

Leave `proxmox.zfs.drives` empty (or remove the key) on a single-disk server where Proxmox VE and the data share the same disk; the setup then skips the pool. The `/tank/immich` and `/tank/filebrowser` paths used by the workloads stay on the VM's own disk unless `cloud_storage.storage.virtiofs_shares` is enabled. Enabling it requires virtiofs devices on the VM and matching shares configured on the Proxmox host; neither is created by this repository yet.

Creation is idempotent: it checks `zpool status` first and only runs `zpool create` when the pool does not exist yet.

Growing the pool: add the new drive to the `drives` list in `config/infra.yaml` and rerun `./prepare-proxmox.sh`. The script detects an existing pool and, after the same confirmation, runs `zpool add -f tank <new-device>` for every configured drive that is not part of the pool yet, so the pool spans all the drives.

CI no longer creates the pool. If the pool is missing later, rerun `./prepare-proxmox.sh` from a machine that can reach the host.

## First-time setup

Run the interactive setup once from a machine that can reach Proxmox:

```bash
cp report-proxmox-state.conf.example report-proxmox-state.conf
./prepare-proxmox.sh
```

Before running it, put at least one administrator public key in `config/ssh/admin/` and fill in `config/infra.yaml` (`access.admin_user`, `access.deploy_user`, and the Cloud Storage VM settings).

The script creates the administrator and deployment users, installs the administrator keys and the host deployment key, creates the API token, creates the ZFS pool, and uploads the repository variables and secrets with the `gh` CLI. It asks for a root password once (hidden) and uploads its hash as `VM_ROOT_PASSWORD_HASH` for VM console access. It verifies the deployment login and then disables root SSH and password authentication. The SSH connection is reused for the rest of the run. `report-proxmox-state.conf` is gitignored because it can contain the Tailscale OAuth secret; never commit it.

The two deployment keys are independent: `PROXMOX_DEPLOY_SSH_KEY` is authorized for `access.deploy_user` on the host, and `CLOUD_STORAGE_DEPLOY_SSH_KEY` is injected into the VM by Terraform. Rotating one never affects the other. Terraform injects the VM key into `cloud_storage.bootstrap_user` (the image's default user, which has passwordless `doas`); the CD pipeline uses that account to create `access.deploy_user`, install `sudo`, and authorize the key before Ansible takes over. The bootstrap step is skipped once the deployment user is reachable. Terraform also derives a bootstrap password from the VM key so cloud-init-created accounts are not locked by PAM-backed sshd; Ansible disables password auth once it takes over.

## Terraform state

State is stored in the S3 backend configured in `terraform/main.tf`, which points at a Cloudflare R2 bucket (S3-compatible API). The plan and apply jobs of the CD pipeline use that backend, so the state is read from and written to the bucket directly.

The state is mirrored to the dedicated `terraform-state` git branch as well; uploading to that branch can be disabled with the `TERRAFORM_STATE_TO_GIT` repository variable. Do not delete the branch: Terraform would no longer know about the existing template and VM and the next apply would try to create them again.

The state contains only infrastructure attributes (VM configuration and the cloud-init public key), plus a masked placeholder for the bootstrap password derived from the VM deployment key. It does not contain the Proxmox API token, the password itself, or any S3 credential.

The plan file is intentionally not uploaded as a workflow artifact. This repository is public and Terraform plan files contain sensitive variable values, so the apply job regenerates the plan locally.

### S3 state backend setup

The optional S3 setup is offered by `./prepare-proxmox.sh` and is configured through the repository variable `TF_STATE_S3_URL` (S3 endpoint URL), the repository variable `TF_STATE_S3_NAME` (S3 bucket name, defaults to `tfstate` when unset), the secret `TF_STATE_S3_KEY_ID` (R2 access key ID), and the secret `TF_STATE_S3_KEY_SECRET` (R2 secret access key). The R2 API token provides the access key ID and secret access key that the Terraform S3 backend uses; no separate token is required.

After configuring the backend, verify it with a test run before relying on it:

```bash
bash scripts/terraform-state.sh test
```

The test initializes the Terraform backend and creates an empty state in the bucket, the same way the pipeline initializes the backend. If the test fails, the script exits with an error and no state is used. If it succeeds, the state upload to the `terraform-state` git branch can be disabled with the `TERRAFORM_STATE_TO_GIT` repository variable.

## SSH host keys

`scripts/proxmox-known-hosts.sh` seeds `known_hosts` with the `PROXMOX_KNOWN_HOSTS` secret and appends freshly scanned keys. A rotated Proxmox host key therefore does not block a deployment.

To enforce a specific key, set the repository variable `PROXMOX_HOST_KEY_FINGERPRINT` to the output of:

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

The deployment then fails when none of the discovered keys match the pinned fingerprint.

## SSH access

Root SSH is disabled on the Proxmox host and on the VM. Use `access.admin_user` with the committed keys for interactive access, or the deployment account for automation. The Proxmox console/noVNC with the root password is the break-glass path.

The host deployment account has no sudo; the privileged host work (ZFS pool, SDN ACL) runs during setup. The VM deployment account has passwordless sudo and the Docker group, which Ansible uses for provisioning.

After the migration, delete the obsolete `PROXMOX_SSH_KEY` repository secret; the workflow now uses `PROXMOX_DEPLOY_SSH_KEY` and `CLOUD_STORAGE_DEPLOY_SSH_KEY`.

## VM networking

The cloud storage VM gets a static address, so cloud-init does not learn DNS from DHCP. Terraform therefore configures the gateway from `cloud_storage.network.gateway` in `config/infra.yaml` as the VM's DNS server. The Ansible playbook also writes `/etc/resolv.conf` with the gateway plus `1.1.1.1`, bounds the Alpine package manager timeouts, and updates the cache with a bounded command. A broken DNS or egress path now fails in minutes with the actual package output instead of hanging.

## Recovering from a failed apply

- **ZFS pool creation failed:** check that `proxmox.zfs.drives` in `config/infra.yaml` lists whole disk devices and that the host was reachable during setup. The pool is created by `./prepare-proxmox.sh`; rerun it before deploying.
- **Host key verification failed:** the workflow refreshes the host key automatically. If it still fails, verify that the `PROXMOX_KNOWN_HOSTS` secret belongs to the current host and that `TS_PROXMOX_HOSTNAME` resolves over Tailscale.
- **`Failed to update the package cache`:** check the network diagnostics that the Ansible job prints before the package tasks. If the VM cannot reach its gateway, fix the gateway from `cloud_storage.network.gateway` in `config/infra.yaml`; if the configured resolver does not answer, the playbook falls back to `1.1.1.1`.
- **Permission check failed (`/sdn/zones/localnetwork/vmbr0`, `SDN.Use`):** the SDN ACL is created during setup. Re-run `./prepare-proxmox.sh` from a machine that can reach the host.
- **Locked out of SSH:** root SSH is disabled by design. Use the Proxmox console/noVNC with the root password, or log in as `access.admin_user` with the committed keys. To restore access, reinstall a key for the administrator account from the console.
- **VM already exists:** restore the `terraform-state` branch or import the existing VM manually before applying again.
