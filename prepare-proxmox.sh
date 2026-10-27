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
	SSH_HOST=${SSH_TARGET#*@}
	SSH_KNOWN_HOST=${SSH_HOST}
	SSH_OPTIONS=()

	[[ "${SSH_TARGET}" != -* ]] || die "SSH connection must not begin with an option."
	[[ "${SSH_TARGET}" != *[[:space:]]* ]] || die "SSH connection must not contain whitespace."
	[[ -n "${SSH_TARGET}" ]] || die "SSH connection is empty."

	if [[ "${connection}" == ssh://* && "${SSH_TARGET}" =~ ^(.+):([0-9]+)$ ]]; then
		SSH_TARGET=${BASH_REMATCH[1]}
		SSH_HOST=${SSH_TARGET#*@}
		SSH_KNOWN_HOST="[${SSH_HOST}]:${BASH_REMATCH[2]}"
		SSH_OPTIONS=(-p "${BASH_REMATCH[2]}")
	fi
}

refresh_ssh_host_key() {
	echo "Refreshing the SSH host key for ${SSH_KNOWN_HOST}..." >&2
	ssh-keygen -R "${SSH_KNOWN_HOST}" >/dev/null 2>&1 || true
	SSH_OPTIONS+=( -o StrictHostKeyChecking=accept-new )
}

prompt_wol_interface() {
	local interfaces interface_choice interface_index

	interfaces=$(ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" \
		"ip -o link show | awk -F': ' '\$2 != \"lo\" {sub(/@.*/, \"\", \$2); print \$2}'") || \
		die "Unable to list network interfaces on ${SSH_TARGET}."
	[[ -n "${interfaces}" ]] || die "No non-loopback network interfaces found on ${SSH_TARGET}."

	echo "Available interfaces on ${SSH_TARGET}:" >&2
	interface_index=1
	while IFS= read -r interface; do
		printf '  %d) %s\n' "${interface_index}" "${interface}" >&2
		((++interface_index))
	done <<< "${interfaces}"

	while :; do
		read -r -p "Interface number or name: " interface_choice || \
			die "Input ended before setup was complete."
		if [[ "${interface_choice}" =~ ^[0-9]+$ ]] &&
			((interface_choice >= 1 && interface_choice < interface_index)); then
			printf '%s' "$(printf '%s\n' "${interfaces}" | sed -n "${interface_choice}p")"
			return
		fi
		if printf '%s\n' "${interfaces}" | grep --fixed-strings --line-regexp --quiet -- "${interface_choice}"; then
			printf '%s' "${interface_choice}"
			return
		fi
		echo "Choose one of the listed interface numbers or names." >&2
	done
}

connection=$(prompt_required "SSH root connection (root@host, ssh://root@host, or SSH config alias)")
parse_connection "${connection}"
refresh_ssh_host_key

pve_api_user=$(prompt_required "Proxmox API username (without @pve) for deployment")
[[ "${pve_api_user}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || \
	die "Proxmox API username must be a valid user name."
[[ "${pve_api_user}" != root ]] || die "Do not use the root API account."

wol_interface=
read -r -p "Enable Wake-on-LAN on a Proxmox interface? [y/N]: " wol_answer
if [[ "${wol_answer}" =~ ^[Yy]$ ]]; then
	wol_interface=$(prompt_wol_interface)
fi

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
	"${pve_api_user}" "${configure_tailscale}" "${tailscale_tag}" \
	"${tailscale_hostname}" "${wol_interface}"
remote_output=$(ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" \
	"bash -s -- ${remote_args}" < "${remote_script}")
printf '%s\n' "${remote_output}" | sed '/^Proxmox API token secret:/d'
api_token_secret=$(printf '%s\n' "${remote_output}" | sed -n 's/^Proxmox API token secret: //p')
[[ -n "${api_token_secret}" ]] || die "Remote setup did not return the Proxmox API token secret."

report_script=${script_directory}/scripts/report-proxmox-state.sh
[[ -f "${report_script}" ]] || die "State report script not found: ${report_script}"
PVE_API_TOKEN_ID="${pve_api_user}@pve!deploy" \
PVE_API_TOKEN_SECRET="${api_token_secret}" \
	bash "${report_script}" "${connection}"

echo
echo "Done. Proxmox API user: ${pve_api_user}@pve"