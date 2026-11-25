# Administrator SSH keys

Put one or more OpenSSH public keys in this directory, one per file, ending in
`.pub`. They are installed for the administrator account on the Proxmox host and
on the Cloud Storage VM. Public keys are safe to commit.

The setup script (`./prepare-proxmox.sh`) refuses to continue when this directory
has no `.pub` files. It can also copy a key here for you when you provide a path
or paste a key at the prompt.

Private keys must never be committed.
