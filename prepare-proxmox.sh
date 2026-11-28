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

validate_username() {
	local user=$1
	local label=$2

	[[ "${user}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || \
		die "${label} must be a valid Linux user name."
	[[ "${user}" != root ]] || die "${label} must not be root."
}

prompt_hidden_required() {
	local prompt=$1
	local value

	while :; do
		read -r -s -p "${prompt}: " value || die "Input ended before setup was complete."
		echo >&2
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
	local interface_report index choice name kind state mac addresses details
	local -a interface_names

	interface_report=$(ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" 'bash -s' <<'EOF'
set -euo pipefail
default_interface=$(ip route show default 2>/dev/null | awk '{ print $5; exit }' || true)
while read -r interface; do
	state=$(cat "/sys/class/net/${interface}/operstate" 2>/dev/null || echo unknown)
	mac=$(cat "/sys/class/net/${interface}/address" 2>/dev/null || echo unknown)
	addresses=$(ip -o addr show dev "${interface}" 2>/dev/null |
		awk '$3 == "inet" || $3 == "inet6" { printf "%s%s", sep, $4; sep = ", " }')
	if [[ -d "/sys/class/net/${interface}/bridge" ]]; then
		kind=bridge
		members=$(ls "/sys/class/net/${interface}/brif" 2>/dev/null | paste -sd, - || true)
		details="bridge${members:+ over ${members}}"
	elif [[ -e "/sys/class/net/${interface}/device" ]]; then
		kind=physical
		driver=$(basename "$(readlink -f "/sys/class/net/${interface}/device/driver" 2>/dev/null)" 2>/dev/null || true)
		pci=$(basename "$(readlink -f "/sys/class/net/${interface}/device" 2>/dev/null)" 2>/dev/null || true)
		model=$(lspci -s "${pci}" 2>/dev/null | sed -e 's/^[^ ]* //' -e 's/^[^:]*: //' || true)
		details="physical${model:+ ${model}}${driver:+ (driver ${driver})}${pci:+, ${pci}}"
		if command -v ethtool >/dev/null 2>&1; then
			wol=$(ethtool "${interface}" 2>/dev/null |
				awk -F: '/Wake-on/ { gsub(/^ +/, "", $2); print $2; exit }' || true)
			details="${details}${wol:+, Wake-on ${wol}}"
		fi
	elif [[ -d "/sys/class/net/${interface}/bonding" ]]; then
		kind=bond
		details=bond
	elif [[ "${interface}" == *.* ]]; then
		kind=vlan
		details=vlan
	else
		kind=virtual
		details=virtual
	fi
	if [[ "${interface}" == "${default_interface}" ]]; then
		details="${details} (default route)"
	fi
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
		"${interface}" "${kind}" "${state}" "${mac}" "${addresses:--}" "${details}"
done < <(ip -o link show | awk -F': ' '$2 != "lo" { sub(/@.*/, "", $2); print $2 }')
EOF
	) || die "Unable to list network interfaces on ${SSH_TARGET}."
	[[ -n "${interface_report}" ]] || die "No non-loopback network interfaces found on ${SSH_TARGET}."

	interface_names=()
	echo "Available interfaces on ${SSH_TARGET}:" >&2
	printf '  %s %-8s %-9s %-6s %-17s %-24s %s\n' \
		"#" "Name" "Type" "State" "MAC" "Addresses" "Details" >&2
	index=1
	while IFS=$'\t' read -r name kind state mac addresses details; do
		interface_names+=("${name}")
		printf '  %d) %-8s %-9s %-6s %-17s %-24s %s\n' \
			"${index}" "${name}" "${kind}" "${state}" "${mac}" "${addresses}" "${details}" >&2
		index=$((index + 1))
	done <<< "${interface_report}"
	echo "Wake-on-LAN must be enabled on a physical NIC, not on a bridge." >&2

	while :; do
		read -r -p "Interface number or name (physical NIC recommended): " choice || \
			die "Input ended before setup was complete."
		if [[ "${choice}" =~ ^[0-9]+$ ]] &&
			((10#${choice} >= 1 && 10#${choice} <= ${#interface_names[@]})); then
			printf '%s' "${interface_names[10#${choice} - 1]}"
			return
		fi
		if printf '%s\n' "${interface_names[@]}" |
			grep --fixed-strings --line-regexp --quiet -- "${choice}"; then
			printf '%s' "${choice}"
			return
		fi
		echo "Choose one of the listed interface numbers or names." >&2
	done
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
	local config_file
	local value

	for config_file in \
		"${script_directory}/report-proxmox-state.conf" \
		"${script_directory}/report-proxmox-state.conf.example"; do
		[[ -f "${config_file}" ]] || continue
		value=$(sed -n "s/^[[:space:]]*${key}=//p" "${config_file}" | tail -n 1)
		if [[ -n "${value}" ]]; then
			printf '%s' "${value}"
			return
		fi
	done
}

read_zfs_drives_from_config() {
	mapfile -t zfs_drives < <(awk '
		/^ *drives:/ {
			in_list = 1
			next
		}
		in_list && /^ *- / {
			gsub(/"/, "")
			sub(/^ *- /, "")
			print
			next
		}
		in_list && !/^ *- / && NF > 0 {
			in_list = 0
		}
	' "${infra_config_file}")
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
report_config_file=${script_directory}/report-proxmox-state.conf

connection=$(prompt_required "SSH root connection (root@host, ssh://root@host, or SSH config alias)")
parse_connection "${connection}"
refresh_ssh_host_key

# Multiplexing keeps one authenticated connection for the whole run, so the
# root password is requested once instead of for every SSH command.
SSH_PLAIN_OPTIONS=("${SSH_OPTIONS[@]}")
ssh_control_directory=$(mktemp --directory)
ssh_control_path=${ssh_control_directory}/%C
SSH_OPTIONS+=(-o ControlMaster=auto -o "ControlPath=${ssh_control_path}" -o ControlPersist=3600)
export PREPARE_SSH_CONTROL_PATH="${ssh_control_path}"
temporary_key_directory=

cleanup() {
	ssh -O exit -o ConnectTimeout=5 "${SSH_OPTIONS[@]}" "${SSH_TARGET}" >/dev/null 2>&1 || true
	rm -rf "${ssh_control_directory}"
	if [[ -n "${temporary_key_directory}" ]]; then
		rm -rf "${temporary_key_directory}"
	fi
}
trap cleanup EXIT

if [[ ! -f "${report_config_file}" && -f "${report_config_file}.example" ]]; then
	cp "${report_config_file}.example" "${report_config_file}"
	echo "Created ${report_config_file} from the example file." >&2
fi

echo
echo "The setup reads configuration from:"
echo "  ${infra_config_file}"
if [[ -f "${report_config_file}" ]]; then
	echo "  ${report_config_file}"
else
	echo "  ${report_config_file} (will be created from report-proxmox-state.conf.example)"
fi
echo "The first value it reads is access.admin_authorized_keys_dir from ${infra_config_file}."
echo "Edit these files now if needed."
read -r -p "Continue? [y/N]: " config_continue_answer
[[ "${config_continue_answer}" =~ ^[Yy]$ ]] || die "Cancelled."

admin_keys_dir_relative=$(read_config_value admin_authorized_keys_dir config/ssh/admin)
zfs_raid_level=$(read_config_value raid_level raidz1)
vm_ip=$(read_config_value ip "")
admin_keys_dir=${script_directory}/${admin_keys_dir_relative}

host_deploy_key_path=${PROXMOX_DEPLOY_KEY_PATH:-}
if [[ -z "${host_deploy_key_path}" ]]; then
	host_deploy_key_path=$(read_report_value GITHUB_PROXMOX_DEPLOY_KEY_PATH)
fi
vm_deploy_key_path=${CLOUD_STORAGE_DEPLOY_KEY_PATH:-}
if [[ -z "${vm_deploy_key_path}" ]]; then
	vm_deploy_key_path=$(read_report_value GITHUB_CLOUD_STORAGE_DEPLOY_KEY_PATH)
fi

pve_api_user=$(read_config_value deploy_api_user "")
[[ -n "${pve_api_user}" ]] || die "Set access.deploy_api_user in ${infra_config_file} before running the setup."
[[ "${pve_api_user}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || \
	die "Proxmox API username must be a valid user name."
[[ "${pve_api_user}" != root ]] || die "Do not use the root API account."

admin_user=$(read_config_value admin_user "")
deploy_user=$(read_config_value deploy_user "")
[[ -n "${admin_user}" ]] || die "Set access.admin_user in ${infra_config_file} before running the setup."
[[ -n "${deploy_user}" ]] || die "Set access.deploy_user in ${infra_config_file} before running the setup."
validate_username "${admin_user}" "Administrator user"
validate_username "${deploy_user}" "Deployment user"
[[ "${admin_user}" != "${deploy_user}" ]] || \
	die "The administrator and deployment users must be different."

admin_keys=()
collect_admin_keys "${admin_keys_dir}" "${admin_user}"

temporary_key_directory=$(mktemp --directory)

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

read_zfs_drives_from_config

case "${zfs_raid_level}" in
raidz1 | raidz2 | raidz3 | mirror)
	zfs_create_options=("${zfs_raid_level}")
	;;
none | single | stripe)
	zfs_create_options=()
	;;
*)
	die "Unsupported proxmox.zfs.raid_level '${zfs_raid_level}' in ${infra_config_file}."
	;;
esac

echo
echo "The script will connect to ${SSH_TARGET} and prepare Proxmox VE."
echo "Administrator user: ${admin_user} (sudo)"
echo "Deployment user: ${deploy_user} (no sudo, jump host only)"
if [[ ${#zfs_drives[@]} -gt 0 ]]; then
	echo
	echo "ZFS pool 'tank' (${zfs_raid_level}) from proxmox.zfs in ${infra_config_file}:"
	printf '  %s\n' "${zfs_drives[@]}"
	echo "Creating the pool wipes these drives; growing an existing pool wipes the added drives."
	echo "Edit ${infra_config_file} now if this list is wrong."
else
	echo "No drives configured in proxmox.zfs.drives; the data pool will be skipped."
fi
echo "The root SSH password will be requested once, directly by SSH."
read -r -p "Continue? [y/N]: " continue_answer
[[ "${continue_answer}" =~ ^[Yy]$ ]] || die "Cancelled."

root_password=$(read_report_value VM_ROOT_PASSWORD)
if [[ -z "${root_password}" ]]; then
	root_password=$(prompt_hidden_required \
		"VM root password (set VM_ROOT_PASSWORD in ${report_config_file} to skip this prompt)")
fi
root_password_hash=$(openssl passwd -6 -salt "$(openssl rand -hex 8)" "${root_password}") || \
	die "Unable to generate the root password hash."
unset root_password

if [[ ${#zfs_drives[@]} -gt 0 ]]; then
	# shellcheck disable=SC2029
	zfs_drive_report=$(ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" \
		"bash -s -- $(printf '%q ' "${zfs_drives[@]}")" <<'EOF'
set -euo pipefail
for drive in "$@"; do
	if [[ -b "${drive}" ]]; then
		lsblk -dn -o NAME,SIZE,MODEL "${drive}" 2>/dev/null || printf '%s\n' "${drive}"
	else
		printf '%s (missing)\n' "${drive}"
	fi
done
EOF
	) || die "Unable to inspect the configured ZFS drives on ${SSH_TARGET}."
	if grep --quiet --fixed-strings '(missing)' <<< "${zfs_drive_report}"; then
		printf '%s\n' "${zfs_drive_report}" | sed 's/^/  /' >&2
		die "Some drives from proxmox.zfs.drives do not exist on ${SSH_TARGET}. Edit ${infra_config_file} and rerun the setup."
	fi
fi

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

if [[ ${#zfs_drives[@]} -gt 0 ]]; then
	zpool_exists=false
	if ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" "zpool status tank >/dev/null 2>&1"; then
		zpool_exists=true
	fi

	if [[ "${zpool_exists}" == true ]]; then
		zfs_pool_status=$(ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" "zpool status tank 2>/dev/null" || true)
		zfs_pool_members=$(printf '%s\n' "${zfs_pool_status}" | awk '$1 ~ /^\/dev\// { print $1 }')
		zfs_pending_drives=()
		for zfs_drive in "${zfs_drives[@]}"; do
			if ! printf '%s\n' "${zfs_pool_members}" | grep -qxF -- "${zfs_drive}"; then
				zfs_pending_drives+=("${zfs_drive}")
			fi
		done
		if [[ ${#zfs_pending_drives[@]} -eq 0 ]]; then
			echo "ZFS pool 'tank' already contains all configured drives."
		else
			echo "Adding drives to ZFS pool 'tank': ${zfs_pending_drives[*]}"
			for zfs_drive in "${zfs_pending_drives[@]}"; do
				# shellcheck disable=SC2029
				ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" "zpool add -f tank ${zfs_drive}"
			done
			echo "ZFS pool 'tank' grown."
		fi
	else
		echo "Creating ZFS pool 'tank' (${zfs_raid_level}) on:"
		printf '%s\n' "${zfs_drive_report}" | sed 's/^/  /'
		zfs_create_command=(zpool create -f tank)
		zfs_create_command+=("${zfs_create_options[@]}")
		zfs_create_command+=("${zfs_drives[@]}")
		# shellcheck disable=SC2029
		ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" "$(printf '%q ' "${zfs_create_command[@]}")"
		echo "ZFS pool 'tank' created."
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
VM_ROOT_PASSWORD_HASH="${root_password_hash}" \
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

ssh_deploy_options=("${SSH_PLAIN_OPTIONS[@]}" -i "${host_deploy_key}" -o IdentitiesOnly=yes \
	-o BatchMode=yes -o "User=${deploy_user}")
if ! ssh "${ssh_deploy_options[@]}" "${SSH_HOST}" true; then
	die "Unable to authenticate as ${deploy_user}@${SSH_HOST} with the deployment key."
fi
echo "Verified ${deploy_user} SSH access."

if ssh "${SSH_PLAIN_OPTIONS[@]}" -o BatchMode=yes -o "User=root" "${SSH_HOST}" true 2>/dev/null; then
	echo "Warning: root SSH still succeeds. Check /etc/ssh/sshd_config.d/10-onprem.conf." >&2
fi

echo
echo "Done. Proxmox API user: ${pve_api_user}@pve"
echo "Administrator user: ${admin_user}"
echo "Deployment user: ${deploy_user}"
echo "Root password hash uploaded as VM_ROOT_PASSWORD_HASH for console access."
