# Deployment

The deployment pipeline is defined in `.github/workflows/deploy.yml` and has four stages:

1. **Terraform Plan** validates the Terraform configuration against the current state.
2. **Terraform Apply** restores the state, refreshes the Proxmox SDN ACL, applies the plan and saves the state.
3. **Run Ansible** installs Docker Engine on the new VM and prepares the deployment directory.
4. **Deploy Docker Workloads** copies `docker/` to the VM and runs `docker compose up`.

## First-time setup

Run the interactive setup once from a machine that can reach Proxmox:

```bash
./prepare-proxmox.sh
```

It configures the Proxmox host, creates the API token, authorizes the deployment SSH key for `root`, and uploads the repository variables and secrets with the `gh` CLI.

If the deployment SSH key was created by an older version of this repository, re-run the setup (or append the public key printed by the workflow to `/root/.ssh/authorized_keys` on the Proxmox host). The workflow intentionally fails with the public key in its log when it cannot authenticate.

## Terraform state

State is stored on the dedicated `terraform-state` branch and is restored at the start of the plan and apply jobs. Do not delete the branch: Terraform would no longer know about the existing template and VM and the next apply would try to create them again.

The state contains only infrastructure attributes (VM configuration and the cloud-init public key). It does not contain the Proxmox API token or any other provider credential.

The plan file is intentionally not uploaded as a workflow artifact. This repository is public and Terraform plan files contain sensitive variable values, so the apply job regenerates the plan locally.

## SSH host keys

`scripts/proxmox-known-hosts.sh` seeds `known_hosts` with the `PROXMOX_KNOWN_HOSTS` secret and appends freshly scanned keys. A rotated Proxmox host key therefore does not block a deployment.

To enforce a specific key, set the repository variable `PROXMOX_HOST_KEY_FINGERPRINT` to the output of:

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

The deployment then fails when none of the discovered keys match the pinned fingerprint.

## Recovering from a failed apply

- **Host key verification failed:** the workflow now refreshes the host key automatically. If it still fails, verify that the `PROXMOX_KNOWN_HOSTS` secret belongs to the current host and that `TS_PROXMOX_HOSTNAME` resolves over Tailscale.
- **Permission check failed (`/sdn/zones/localnetwork/vmbr0`, `SDN.Use`):** the SDN ACL step could not run. Check the SSH key authorization message and re-run `./prepare-proxmox.sh`.
- **VM already exists:** restore the `terraform-state` branch or import the existing VM manually before applying again.
