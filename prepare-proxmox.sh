#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_NAME

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

prompt_with_default() {
	local prompt=$1
	local default=$2
	local value

	read -r -p "${prompt} [${default}]: " value || die "Input ended before setup was complete."
	printf '%s' "${value:-${default}}"
}

validate_username() {
	local user=$1
	local label=$2

	[[ "${user}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || \
		die "${label} must be a valid Linux user name."
	[[ "${user}" != root ]] || die "${label} must not be root."
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
		echo "Choose one of the listed interfaces numbers or names." >&2
	done
}

write_zfs_pool() {
	local drives=$1
	local temporary_file
	local infra_config_file
	temporary_file=$(mktemp)
	infra_config_file=${script_directory}/config/infra.yaml
	awk -v drives="${drives}" '
		/^ *drives:/ {
			in_list = 1
			print
			count = split(drives, items, ",")
			for (i = 1; i <= count; i++) {
				printf "      - \"%s\"\n", items[i]
			}
			next
		}
		in_list && /^ *- / { next }
		in_list && !/^ *- / && NF > 0 { in_list = 0 }
		{ print }
	' "${infra_config_file}" > "${temporary_file}"
	mv "${temporary_file}" "${infra_config_file}"
	chmod 0644 "${infra_config_file}"
}

read_config_value() {
	local key=$1
	local default=$2
	local value

	value=$(sed -n "s/^[[:space:]]*${key}:[[:space:]]*\"\([^\"]*\)\".*$/\1/p" "${infra_config_file}" | head -n 1)
	printf '%s' "${value:-${default}}"
}

read_report_value() {
	local key=$1
	local config_file=${script_directory}/report-proxmox-state.conf

	[[ -f "${config_file}" ]] || return 0
	sed -n "s/^[[:space:]]*${key}=//p" "${config_file}" | tail -n 1
}

read_zfs_drives_from_config() {
	local drives_raw
	local drive_items

	drives_raw=$(awk '
		/^ *drives:/ {
			in_list = 1
			next
		}
		in_list && /^ *- / {
			gsub(/"/, "", $0)
			print $0
			next
		}
		in_list && !/^ *- / && NF > 0 {
			in_list = 0
		}
	' "${infra_config_file}")

	zfs_drives=()
	if [[ -n "${drives_raw}" ]]; then
		read -r -a drive_items <<< "${drives_raw}"
		zfs_drives=("${drive_items[@]}")
	fi
}

collect_admin_keys() {
	local keys_dir=$1
	local admin_user=$2
	local -a key_files
	local key_file
	local key_input

	mkdir -p "${keys_dir}"
	mapfile -t key_files < <(find "${keys_dir}" -maxdepth 1 -type f -name '*.pub' | sort)

	if [[ ${#key_files[@]} -eq 0 ]]; then
		read -r -p "Path to an administrator public key (or paste the key): " key_input || \
			die "Input ended before setup was complete."
		[[ -n "${key_input}" ]] || die "At least one administrator public key is required."
		if [[ -f "${key_input}" ]]; then
			cp "${key_input}" "${keys_dir}/$(basename "${key_input}")"
		else
			[[ "${key_input}" == ssh-* || "${key_input}" == ecdsa-* || "${key_input}" == sk-* ]] || \
				die "Expected an OpenSSH public key."
			printf '%s\n' "${key_input}" > "${keys_dir}/${admin_user}.pub"
		fi
		mapfile -t key_files < <(find "${keys_dir}" -maxdepth 1 -type f -name '*.pub' | sort)
	fi

	[[ ${#key_files[@]} -gt 0 ]] || die "At least one administrator public key is required."
	admin_keys=()
	for key_file in "${key_files[@]}"; do
		local key_type
		key_type=$(awk '{print $1; exit}' "${key_file}")
		[[ "${key_type}" == ssh-* || "${key_type}" == ecdsa-* || "${key_type}" == sk-* ]] || \
			die "Not an OpenSSH public key: ${key_file}"
		ssh-keygen -lf "${key_file}" >/dev/null 2>&1 || die "Invalid SSH public key: ${key_file}"
		admin_keys+=("$(<"${key_file}")")
	done
}

prepare_deploy_key() {
	local requested_path=$1
	local default_path=$2
	local comment=$3
	local key_file=${requested_path:-generate}

	if [[ "${key_file}" == generate ]]; then
		key_file=${default_path}
		ssh-keygen -q -t ed25519 -N '' -C "${comment}" -f "${key_file}" || \
			die "Unable to generate an Ed25519 key at ${key_file}."
	elif [[ ! -f "${key_file}" ]]; then
		die "SSH key file not found: ${key_file}"
	fi

	key_file=$(cd -- "$(dirname -- "${key_file}")" && pwd)/$(basename -- "${key_file}")
	printf '%s' "${key_file}"
}

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
infra_config_file=${script_directory}/config/infra.yaml
[[ -f "${infra_config_file}" ]] || die "Infrastructure configuration file not found: ${infra_config_file}"

admin_user_default=$(read_config_value admin_user admin)
deploy_user_default=$(read_config_value deploy_user deployer)
admin_keys_dir_relative=$(read_config_value admin_authorized_keys_dir config/ssh/admin)
zfs_raid_level=$(read_config_value raid_level raidz1)
vm_ip=$(read_config_value ip "")
admin_keys_dir=${script_directory}/${admin_keys_dir_relative}
report_config_file=${script_directory}/report-proxmox-state.conf

host_deploy_key_path=${PROXMOX_DEPLOY_KEY_PATH:-}
if [[ -z "${host_deploy_key_path}" && -f "${report_config_file}" ]]; then
	host_deploy_key_path=$(read_report_value GITHUB_PROXMOX_DEPLOY_KEY_PATH)
fi
vm_deploy_key_path=${CLOUD_STORAGE_DEPLOY_KEY_PATH:-}
if [[ -z "${vm_deploy_key_path}" && -f "${report_config_file}" ]]; then
	vm_deploy_key_path=$(read_report_value GITHUB_CLOUD_STORAGE_DEPLOY_KEY_PATH)
fi

connection=$(prompt_required "SSH root connection (root@host, ssh://root@host, or SSH config alias)")
parse_connection "${connection}"
refresh_ssh_host_key

pve_api_user=$(prompt_required "Proxmox API username (without @pve) for deployment")
[[ "${pve_api_user}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || \
	die "Proxmox API username must be a valid user name."
[[ "${pve_api_user}" != root ]] || die "Do not use the root API account."

admin_user=$(prompt_with_default "Administrator username" "${admin_user_default}")
validate_username "${admin_user}" "Administrator user"
deploy_user=$(prompt_with_default "Deployment username" "${deploy_user_default}")
validate_username "${deploy_user}" "Deployment user"
[[ "${admin_user}" != "${deploy_user}" ]] || \
	die "The administrator and deployment users must be different."

admin_keys=()
collect_admin_keys "${admin_keys_dir}" "${admin_user}"

temporary_key_directory=$(mktemp --directory)
cleanup_temporary_key_directory() {
	rm -rf "${temporary_key_directory}"
}
trap cleanup_temporary_key_directory EXIT

host_deploy_key=$(prepare_deploy_key "${host_deploy_key_path:-generate}" \
	"${temporary_key_directory}/proxmox_deploy" "onprem proxmox deploy")
vm_deploy_key=$(prepare_deploy_key "${vm_deploy_key_path:-generate}" \
	"${temporary_key_directory}/cloud_storage_deploy" "onprem cloud storage deploy")
deploy_public_key=$(ssh-keygen -y -f "${host_deploy_key}")
admin_keys_b64=$(printf '%s\n' "${admin_keys[@]}" | base64 -w0)

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
echo "Administrator user: ${admin_user} (sudo)"
echo "Deployment user: ${deploy_user} (no sudo, jump host only)"
echo "The root SSH password will be requested once, directly by SSH."
read -r -p "Continue? [y/N]: " continue_answer
[[ "${continue_answer}" =~ ^[Yy]$ ]] || die "Cancelled."

echo "Preparing the Proxmox host..."
remote_script=${script_directory}/prepare-proxmox-remote.sh
[[ -f "${remote_script}" ]] || die "Remote script not found: ${remote_script}"

printf -v remote_args '%q ' \
	"${pve_api_user}" "${configure_tailscale}" "${tailscale_tag}" \
	"${tailscale_hostname}" "${wol_interface}" "${admin_user}" \
	"${deploy_user}" "${deploy_public_key}" "${admin_keys_b64}"
# shellcheck disable=SC2029
remote_output=$(ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" \
	"bash -s -- ${remote_args}" < "${remote_script}")
printf '%s\n' "${remote_output}" | sed '/^Proxmox API token secret:/d'
api_token_secret=$(printf '%s\n' "${remote_output}" | sed -n 's/^Proxmox API token secret: //p')
[[ -n "${api_token_secret}" ]] || die "Remote setup did not return the Proxmox API token secret."

config_file=${script_directory}/report-proxmox-state.conf
if [[ ! -f "${config_file}" && -f "${config_file}.example" ]]; then
	cp "${config_file}.example" "${config_file}"
	echo "Created ${config_file}; fill it in when prompted." >&2
fi

read_zfs_drives_from_config

zfs_pool_exists=false
if ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" "zpool status tank >/dev/null 2>&1"; then
	zfs_pool_exists=true
fi

if [[ "${zfs_pool_exists}" == true ]]; then
	zfs_pool_status=$(ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" "zpool status tank 2>/dev/null" || true)
	zfs_pool_members=$(printf '%s\n' "${zfs_pool_status}" | awk '$1 ~ /^\/dev\// { print $1 }')
	zfs_added_drives=
	for zfs_drive in "${zfs_drives[@]}"; do
		if ! printf '%s\n' "${zfs_pool_members}" | grep -qxF -- "${zfs_drive}"; then
			# shellcheck disable=SC2029
			ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" "zpool add -f tank ${zfs_drive}"
			zfs_added_drives="${zfs_added_drives:+${zfs_added_drives} }${zfs_drive}"
		fi
	done
	if [[ -n "${zfs_added_drives}" ]]; then
		echo "ZFS pool 'tank' grown with: ${zfs_added_drives}"
	else
		echo "ZFS pool 'tank' already contains all configured drives."
	fi
else
	zfs_pool_drives=
	read -r -p "Set up a dedicated drive for application data (photos, media, ...)? [y/N]: " zfs_data_answer
	if [[ "${zfs_data_answer}" =~ ^[Yy]$ ]]; then
		mapfile -t zfs_disk_list < <(ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" \
			"lsblk -d -o NAME,SIZE 2>/dev/null | tail -n +2")
		if [[ ${#zfs_disk_list[@]} -gt 0 ]]; then
			echo "Available disks on ${SSH_TARGET}:" >&2
			zfs_index=1
			for zfs_drive in "${zfs_disk_list[@]}"; do
				printf '  %d) %s\n' "${zfs_index}" "${zfs_drive}"
				zfs_index=$((zfs_index + 1))
			done
			read -r -p "Select disk indices for the ZFS pool (comma-separated): " zfs_selection
			[[ "${zfs_selection}" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "Selection must be comma-separated numbers, for example 1,2,3."
			IFS=',' read -r -a zfs_chosen <<< "${zfs_selection}"
			for zfs_idx in "${zfs_chosen[@]}"; do
				if ((10#${zfs_idx} < 1 || 10#${zfs_idx} > ${#zfs_disk_list[@]})); then
					die "Disk index ${zfs_idx} is out of range."
				fi
				zfs_drive_line="${zfs_disk_list[$((10#${zfs_idx} - 1))]}"
				read -r -a zfs_drive_parts <<< "${zfs_drive_line}"
				zfs_pool_drives="${zfs_pool_drives:+${zfs_pool_drives},}/dev/${zfs_drive_parts[0]}"
			done
		fi
		if [[ -n "${zfs_pool_drives}" ]]; then
			write_zfs_pool "${zfs_pool_drives}"
			zfs_pool_devices=${zfs_pool_drives//,/ }
			# shellcheck disable=SC2029
			ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" \
				"if ! zpool status tank >/dev/null 2>&1; then zpool create -f tank ${zfs_raid_level} ${zfs_pool_devices}; fi"
		fi
	fi
fi

proxmox_host_key_fingerprint=
proxmox_host_key_fingerprint=$(ssh-keyscan -H "${SSH_HOST}" 2>/dev/null | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' | head -n 1 || true)
if [[ -n "${proxmox_host_key_fingerprint}" ]]; then
	export PROXMOX_HOST_KEY_FINGERPRINT="${proxmox_host_key_fingerprint}"
	echo "Discovered Proxmox host key fingerprint: ${proxmox_host_key_fingerprint}" >&2
fi

report_script=${script_directory}/scripts/report-proxmox-state.sh
[[ -f "${report_script}" ]] || die "State report script not found: ${report_script}"
PROXMOX_DEPLOY_USER="${deploy_user}" \
GITHUB_PROXMOX_DEPLOY_KEY_PATH="${host_deploy_key}" \
GITHUB_CLOUD_STORAGE_DEPLOY_KEY_PATH="${vm_deploy_key}" \
PVE_API_TOKEN_ID="${pve_api_user}@pve!deploy" \
PVE_API_TOKEN_SECRET="${api_token_secret}" \
	bash "${report_script}" "${connection}"

echo
echo "Before root SSH is disabled, make sure you can log in as ${admin_user}:"
echo "  ssh -i <your-admin-key> ${admin_user}@${SSH_HOST}"
read -r -p "Disable root SSH and password authentication now? [Y/n]: " harden_answer
if [[ ! "${harden_answer}" =~ ^[Nn]$ ]]; then
	[[ -n "${vm_ip}" ]] || die "cloud_storage.network.ip must be set in config/infra.yaml before hardening SSH."
	# shellcheck disable=SC2029
	ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" \
		"bash -s -- $(printf '%q' "${admin_user}") $(printf '%q' "${deploy_user}") $(printf '%q' "${vm_ip}")" <<'EOF'
set -euo pipefail
admin_user=$1
deploy_user=$2
vm_ip=$3

install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-onprem.conf <<CONF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
AllowUsers ${admin_user} ${deploy_user}

Match User ${deploy_user}
    AllowTcpForwarding yes
    PermitOpen ${vm_ip}:22
    PermitTTY no
    AllowAgentForwarding no
Match all
CONF

if ! grep --quiet '^Include /etc/ssh/sshd_config.d/\*.conf' /etc/ssh/sshd_config; then
	sed --in-place '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
fi

/usr/sbin/sshd -t
systemctl reload ssh
EOF
	echo "Root SSH and password authentication are disabled."
fi

ssh_deploy_options=("${SSH_OPTIONS[@]}" -i "${host_deploy_key}" -o IdentitiesOnly=yes \
	-o BatchMode=yes -o "User=${deploy_user}")
if ! ssh "${ssh_deploy_options[@]}" "${SSH_HOST}" true; then
	die "Unable to authenticate as ${deploy_user}@${SSH_HOST} with the deployment key."
fi
echo "Verified ${deploy_user} SSH access."

if ssh "${SSH_OPTIONS[@]}" -o BatchMode=yes -o "User=root" "${SSH_HOST}" true 2>/dev/null; then
	echo "Warning: root SSH still succeeds. Check /etc/ssh/sshd_config.d/10-onprem.conf." >&2
fi

echo
echo "Done. Proxmox API user: ${pve_api_user}@pve"
echo "Administrator user: ${admin_user}"
echo "Deployment user: ${deploy_user}"
