#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_NAME=$(basename "$0")

die() {
	echo "${SCRIPT_NAME}: $*" >&2
	exit 1
}

prompt_required() {
	local prompt=$1
	local value

	while :; do
		read -r -p "${prompt}: " value || die "Input ended before setup was complete."
		if [[ -n "${value}" ]]; then
			printf '%s' "${value}"
			return
		fi
		echo "A value is required." >&2
	done
}

parse_connection() {
	local connection=$1

	SSH_TARGET=${connection#ssh://}
	SSH_OPTIONS=()

	[[ "${SSH_TARGET}" != -* ]] || die "SSH connection must not begin with an option."
	[[ "${SSH_TARGET}" != *[[:space:]]* ]] || die "SSH connection must not contain whitespace."
	[[ -n "${SSH_TARGET}" ]] || die "SSH connection is empty."

	if [[ "${connection}" == ssh://* && "${SSH_TARGET}" =~ ^(.+):([0-9]+)$ ]]; then
		SSH_TARGET=${BASH_REMATCH[1]}
		SSH_OPTIONS=(-p "${BASH_REMATCH[2]}")
	fi
}

connection=$(prompt_required "SSH connection (user@host, ssh://user@host, or SSH config alias)")
parse_connection "${connection}"

deploy_user=$(prompt_required "Deployment username")
[[ "${deploy_user}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || \
	die "Deployment username must be a valid Linux login name."
[[ "${deploy_user}" != root ]] || die "Do not replace the root account."

default_key_path=${HOME}/.ssh/id_ed25519.pub
read -r -p "Public SSH key path [${default_key_path}]: " key_path
key_path=${key_path:-${default_key_path}}
[[ -f "${key_path}" ]] || die "Public key file not found: ${key_path}"
ssh-keygen -lf "${key_path}" >/dev/null || die "The file is not a valid SSH public key."
public_key=$(<"${key_path}")
[[ -n "${public_key}" ]] || die "Public key file is empty."

configure_tailscale=false
read -r -p "Install and configure Tailscale on the Proxmox host? [y/N]: " tailscale_answer
if [[ "${tailscale_answer}" =~ ^[Yy]$ ]]; then
	configure_tailscale=true
fi

echo
echo "The script will connect to ${SSH_TARGET} and prepare Proxmox VE."
echo "The remote sudo prompt, if needed, will appear directly in this terminal."
read -r -p "Continue? [y/N]: " continue_answer
[[ "${continue_answer}" =~ ^[Yy]$ ]] || die "Cancelled."

echo "Checking SSH access and sudo availability..."
ssh "${SSH_OPTIONS[@]}" -tt "${SSH_TARGET}" \
	'set -e; if [ "$(id -u)" -ne 0 ]; then command -v sudo >/dev/null || { echo "sudo is required for a non-root SSH account." >&2; exit 1; }; sudo -v; fi'

printf -v remote_args '%q ' "${deploy_user}" "${public_key}" "${configure_tailscale}"

echo "Preparing the Proxmox host..."
ssh "${SSH_OPTIONS[@]}" -tt "${SSH_TARGET}" \
	"if [ \"\$(id -u)\" -eq 0 ]; then exec bash -s -- ${remote_args}; else exec sudo -n bash -s -- ${remote_args}; fi" <<'REMOTE_SCRIPT'
set -euo pipefail

deploy_user=$1
public_key=$2
configure_tailscale=$3

[[ -f /etc/pve/.version ]] || {
	echo "This host does not appear to be a Proxmox VE node (/etc/pve/.version is missing)." >&2
	exit 1
}

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install --yes ca-certificates curl openssh-server sudo

if ! id "${deploy_user}" >/dev/null 2>&1; then
	useradd --create-home --shell /bin/bash "${deploy_user}"
fi

usermod --lock --shell /bin/bash "${deploy_user}"
usermod --append --groups sudo "${deploy_user}"

install --directory --owner="${deploy_user}" --group="${deploy_user}" --mode=0700 \
	"/home/${deploy_user}/.ssh"
printf '%s\n' "${public_key}" > "/home/${deploy_user}/.ssh/authorized_keys"
chown "${deploy_user}:${deploy_user}" "/home/${deploy_user}/.ssh/authorized_keys"
chmod 0600 "/home/${deploy_user}/.ssh/authorized_keys"

printf '%s\n' "${deploy_user} ALL=(ALL:ALL) NOPASSWD: ALL" \
	> "/etc/sudoers.d/${deploy_user}"
chmod 0440 "/etc/sudoers.d/${deploy_user}"
visudo --check --file="/etc/sudoers.d/${deploy_user}"

if [[ "${configure_tailscale}" == true ]]; then
	if ! command -v tailscale >/dev/null 2>&1; then
		curl --fail --show-error --silent --location https://tailscale.com/install.sh | sh
	fi
	echo "Tailscale will now open its normal authentication flow. Complete it in this terminal."
	tailscale up
fi

systemctl enable --now ssh

echo
echo "Proxmox preparation complete."
echo "Deployment user: ${deploy_user}"
REMOTE_SCRIPT

echo
echo "Done. Use ${deploy_user}@${SSH_TARGET} for the Proxmox SSH user where the workflow requires it."