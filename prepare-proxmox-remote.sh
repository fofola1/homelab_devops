#!/usr/bin/env bash
set -euo pipefail

deploy_user=$1
public_key=$2
configure_tailscale=$3
tailscale_tag=$4
tailscale_hostname=$5

[[ "$(id -u)" -eq 0 ]] || {
	echo "This script must connect as root so the SSH password is entered only once." >&2
	exit 1
}

[[ -f /etc/pve/.version ]] || {
	echo "This host does not appear to be a Proxmox VE node (/etc/pve/.version is missing)." >&2
	exit 1
}

disable_enterprise_sources() {
	local source_file

	while IFS= read -r -d '' source_file; do
		if grep --quiet 'enterprise.proxmox.com' "${source_file}"; then
			mv "${source_file}" "${source_file}.disabled"
		fi
	done < <(find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) -print0)

	if grep --quiet 'enterprise.proxmox.com' /etc/apt/sources.list 2>/dev/null; then
		sed --in-place '/enterprise.proxmox.com/s/^/# Disabled by prepare-proxmox.sh: /' /etc/apt/sources.list
	fi
}

add_no_subscription_source() {
	local codename
	codename=$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")

	if [[ -z "${codename}" ]]; then
		echo "Unable to determine the Debian release codename for the Proxmox repository." >&2
		exit 1
	fi

	if ! grep --quiet --recursive --include='*.list' --include='*.sources' \
		'download.proxmox.com/debian/pve' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
		printf 'deb http://download.proxmox.com/debian/pve %s pve-no-subscription\n' "${codename}" \
			> /etc/apt/sources.list.d/pve-no-subscription.list
	fi
}

disable_enterprise_sources
add_no_subscription_source

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
	tailscale_args=()
	if [[ -n "${tailscale_tag}" ]]; then
		tailscale_args+=("--advertise-tags=${tailscale_tag}")
	fi
	if [[ -n "${tailscale_hostname}" ]]; then
		tailscale_args+=("--hostname=${tailscale_hostname}")
	fi
	tailscale up "${tailscale_args[@]}"
fi

systemctl enable --now ssh

echo
echo "Proxmox preparation complete."
echo "Deployment user: ${deploy_user}"
