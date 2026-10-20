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

connection=$(prompt_required "SSH root connection (root@host, ssh://root@host, or SSH config alias)")
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
tailscale_tag=
tailscale_hostname=
read -r -p "Install and configure Tailscale on the Proxmox host? [y/N]: " tailscale_answer
if [[ "${tailscale_answer}" =~ ^[Yy]$ ]]; then
	configure_tailscale=true
	read -r -p "Tailscale tag (optional, e.g. tag:proxmox): " tailscale_tag
	read -r -p "Tailscale name (optional, leave blank for default): " tailscale_hostname
fi

echo
echo "The script will connect to ${SSH_TARGET} and prepare Proxmox VE."
echo "The root SSH password will be requested once, directly by SSH."
read -r -p "Continue? [y/N]: " continue_answer
[[ "${continue_answer}" =~ ^[Yy]$ ]] || die "Cancelled."

echo "Preparing the Proxmox host..."
script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
remote_script=${script_directory}/prepare-proxmox-remote.sh
[[ -f "${remote_script}" ]] || die "Remote script not found: ${remote_script}"

printf -v remote_args '%q ' \
	"${deploy_user}" "${public_key}" "${configure_tailscale}" \
	"${tailscale_tag}" "${tailscale_hostname}"
ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" \
	"bash -s -- ${remote_args}" < "${remote_script}"

echo
echo "Done. Use ${deploy_user}@${SSH_TARGET} for the Proxmox SSH user where the workflow requires it."