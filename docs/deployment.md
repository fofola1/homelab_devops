# Deployment

The deployment pipeline is defined in `.github/workflows/deploy.yml` and has five stages:

1. **Run Ansible (Host)** prepares the Proxmox host storage before Terraform runs.
2. **Terraform Plan** validates the Terraform configuration against the current state.
3. **Terraform Apply** restores the state, refreshes the Proxmox SDN ACL, applies the plan and saves the state.
4. **Run Ansible (Cloud Storage)** installs Docker Engine on the new VM, loads the virtiofs kernel module, and prepares the shared storage mounts and the deployment directory.
5. **Deploy Cloud Storage Workloads** copies `docker/` to the VM and runs `docker compose up`.

The Terraform stages resolve the template profile selected by the `CLOUD_STORAGE_TEMPLATE` repository variable from `terraform/templates/` before planning and uploading the cloud image; the image URL, file name, checksum, and checksum algorithm therefore live only in the profile file.

## ZFS pool (host storage)

The **Run Ansible (Host)** stage runs before Terraform and creates the ZFS pool on the Proxmox host. The pool name is fixed by the playbook (`tank`). It is created from the whole disks listed in the committed `config/infra.yaml` (`proxmox.zfs.drives`) with the RAID level from `proxmox.zfs.raid_level`.

The stage runs when change detection marks the `ansible/`, `terraform/`, or `config/` paths, or when `force_deploy` is enabled. Terraform then plans the Cloud Storage VM disk on the new pool.

The interactive setup (`prepare-proxmox.sh`) asks whether to set up a dedicated drive for application data (photos, media, ...). When answered yes, it lists the whole disks on the Proxmox host over SSH, lets the user pick the disks, and writes the selection into `config/infra.yaml`.

## First-time setup

Run the interactive setup once from a machine that can reach Proxmox:

```bash
cp report-proxmox-state.conf.example report-proxmox-state.conf
./prepare-proxmox.sh
```

The infrastructure configuration itself lives in the committed `config/infra.yaml`; fill it in there before the first deployment.

It configures the Proxmox host, creates the API token, authorizes the deployment SSH key for `root`, and uploads the remaining repository variables and secrets with the `gh` CLI. `report-proxmox-state.conf` is gitignored because it can contain the Tailscale OAuth secret; never commit it.

If the deployment SSH key was created by an older version of this repository, re-run the setup (or append the public key printed by the workflow to `/root/.ssh/authorized_keys` on the Proxmox host). The workflow intentionally fails with the public key in its log when it cannot authenticate.

## Terraform state

State is stored in the S3 backend configured in `terraform/main.tf`, which points at a Cloudflare R2 bucket (S3-compatible API). The plan and apply jobs of the CD pipeline use that backend, so the state is read from and written to the bucket directly.

The state is mirrored to the dedicated `terraform-state` git branch as well; uploading to that branch can be disabled with the `TERRAFORM_STATE_TO_GIT` repository variable. Do not delete the branch: Terraform would no longer know about the existing template and VM and the next apply would try to create them again.

The state contains only infrastructure attributes (VM configuration and the cloud-init public key). It does not contain the Proxmox API token or any S3 credential.

The plan file is intentionally not uploaded as a workflow artifact. This repository is public and Terraform plan files contain sensitive variable values, so the apply job regenerates the plan locally.

### S3 state backend setup

The optional S3 setup is offered by `./prepare-proxmox.sh` and is configured through the repository variable `TF_STATE_S3_URL` (S3 endpoint URL), the repository variable `TF_STATE_S3_NAME` (S3 bucket name), the secret `TF_STATE_S3_KEY_ID` (R2 access key ID), and the secret `TF_STATE_S3_KEY_SECRET` (R2 secret access key). The R2 API token provides the access key ID and secret access key that the Terraform S3 backend uses; no separate token is required.

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

## VM networking

The cloud storage VM gets a static address, so cloud-init does not learn DNS from DHCP. Terraform therefore configures the gateway from `cloud_storage.network.gateway` in `config/infra.yaml` as the VM's DNS server. The Ansible playbook also writes `/etc/resolv.conf` with the gateway plus `1.1.1.1`, bounds the Alpine package manager timeouts, and updates the cache with a bounded command. A broken DNS or egress path now fails in minutes with the actual package output instead of hanging.

## Recovering from a failed apply

- **ZFS pool creation failed:** check that `proxmox.zfs.drives` in `config/infra.yaml` lists whole disk devices and that the runner could reach the Proxmox host over SSH. The Ansible host stage fails before Terraform runs, so no VM plan is attempted against a missing pool.
- **Host key verification failed:** the workflow now refreshes the host key automatically. If it still fails, verify that the `PROXMOX_KNOWN_HOSTS` secret belongs to the current host and that `TS_PROXMOX_HOSTNAME` resolves over Tailscale.
- **`Failed to update the package cache`:** check the network diagnostics that the Ansible job prints before the package tasks. If the VM cannot reach its gateway, fix the gateway from `cloud_storage.network.gateway` in `config/infra.yaml`; if the configured resolver does not answer, the playbook falls back to `1.1.1.1`.
- **Permission check failed (`/sdn/zones/localnetwork/vmbr0`, `SDN.Use`):** the SDN ACL step could not run. Check the SSH key authorization message and re-run `./prepare-proxmox.sh`.
- **VM already exists:** restore the `terraform-state` branch or import the existing VM manually before applying again.
