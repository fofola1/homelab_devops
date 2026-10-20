#!/usr/bin/env bash
set -euo pipefail

pve_api_user=$1
configure_tailscale=$2
tailscale_tag=$3
tailscale_hostname=$4
wol_interface=$5

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
apt-get install --yes ca-certificates curl ethtool openssh-server

pveum user add "${pve_api_user}@pve" -comment "GitHub Actions API" 2>/dev/null || true
pveum acl modify / -user "${pve_api_user}@pve" -role PVEVMAdmin
token_output=$(pveum user token add "${pve_api_user}@pve" deploy --privsep 0 --output-format json)
token_secret=$(printf '%s' "${token_output}" | sed -n 's/.*"value"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
[[ -n "${token_secret}" ]] || {
	echo "Unable to read the new Proxmox API token secret." >&2
	exit 1
}

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

if [[ -n "${wol_interface}" ]]; then
	ip link show "${wol_interface}" >/dev/null
	ethtool -s "${wol_interface}" wol g
	cat > /usr/local/sbin/enable-proxmox-wol <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ethtool -s "$1" wol g
EOF
	chmod 0755 /usr/local/sbin/enable-proxmox-wol
	cat > /etc/systemd/system/proxmox-wol.service <<EOF
[Unit]
Description=Enable Wake-on-LAN for ${wol_interface}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/enable-proxmox-wol ${wol_interface}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable --now proxmox-wol.service
fi

echo
echo "Proxmox preparation complete."
echo "Proxmox API user: ${pve_api_user}@pve"
echo "Proxmox API token ID: ${pve_api_user}@pve!deploy"
echo "Proxmox API token secret: ${token_secret}"
