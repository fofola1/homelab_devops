#!/usr/bin/env bash
set -euo pipefail

pve_api_user=$1
configure_tailscale=$2
tailscale_tag=$3
tailscale_hostname=$4
wol_interface=$5
admin_user=$6
deploy_user=$7
deploy_public_key=$8
admin_keys_b64=$9

[[ "$(id -u)" -eq 0 ]] || {
	echo "This script must connect as root so the SSH password is entered only once." >&2
	exit 1
}

[[ -f /etc/pve/.version ]] || {
	echo "This host does not appear to be a Proxmox VE node (/etc/pve/.version is missing)." >&2
	exit 1
}

validate_user() {
	local user=$1
	local label=$2
	[[ "${user}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || {
		echo "${label} must be a valid Linux user name." >&2
		exit 1
	}
	[[ "${user}" != root ]] || {
		echo "${label} must not be root." >&2
		exit 1
	}
}

validate_user "${admin_user}" "Administrator user"
validate_user "${deploy_user}" "Deployment user"
[[ "${admin_user}" != "${deploy_user}" ]] || {
	echo "The administrator and deployment users must be different." >&2
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
	# shellcheck disable=SC1091
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
apt-get install --yes ca-certificates curl ethtool openssh-server sudo

ensure_linux_user() {
	local user=$1
	if id "${user}" >/dev/null 2>&1; then
		usermod --shell /bin/bash "${user}"
	else
		useradd --create-home --shell /bin/bash "${user}"
	fi
}

ensure_linux_user "${admin_user}"
ensure_linux_user "${deploy_user}"

usermod --append --groups sudo "${admin_user}"
# The deployment account must not be able to escalate on the host. The
# privileged host work (ZFS pool, SDN ACL) runs during setup instead.
gpasswd --delete "${deploy_user}" sudo >/dev/null 2>&1 || true
gpasswd --delete "${deploy_user}" wheel >/dev/null 2>&1 || true

install_authorized_keys() {
	local user=$1
	local keys=$2
	local home
	home=$(getent passwd "${user}" | cut -d: -f6)
	[[ -n "${home}" ]] || {
		echo "Unable to determine the home directory for ${user}." >&2
		exit 1
	}
	install -d -m 0700 "${home}/.ssh"
	chown "${user}:" "${home}/.ssh"
	printf '%s\n' "${keys}" > "${home}/.ssh/authorized_keys"
	chown "${user}:" "${home}/.ssh/authorized_keys"
	chmod 0600 "${home}/.ssh/authorized_keys"
}

admin_keys=$(printf '%s' "${admin_keys_b64}" | base64 --decode)
install_authorized_keys "${admin_user}" "${admin_keys}"
install_authorized_keys "${deploy_user}" "${deploy_public_key}"

pveum user add "${pve_api_user}@pve" -comment "GitHub Actions API" 2>/dev/null || true
# query-url requires Sys.Modify in addition to the storage and VM privileges.
# Keep this role scoped to the Terraform operations instead of granting Administrator.
terraform_privileges='Sys.Audit Sys.Modify Datastore.Audit Datastore.AllocateSpace Datastore.AllocateTemplate VM.Audit VM.Allocate VM.Clone VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.PowerMgmt SDN.Use'
pveum role add onprem-terraform --privs "${terraform_privileges}" 2>/dev/null || \
	pveum role modify onprem-terraform --privs "${terraform_privileges}"
pveum acl modify / -user "${pve_api_user}@pve" -role onprem-terraform
pveum acl modify /sdn -user "${pve_api_user}@pve" -role onprem-terraform
# SDN.Use checks the concrete SDN zone/vnet path during VM creation.
pveum acl modify /sdn/zones/localnetwork/vmbr0 -user "${pve_api_user}@pve" -role onprem-terraform
pveum user token remove "${pve_api_user}@pve" deploy 2>/dev/null || true
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
echo "Administrator user: ${admin_user}"
echo "Deployment user: ${deploy_user}"
echo "Proxmox API user: ${pve_api_user}@pve"
echo "Proxmox API token ID: ${pve_api_user}@pve!deploy"
echo "Proxmox API token secret: ${token_secret}"
