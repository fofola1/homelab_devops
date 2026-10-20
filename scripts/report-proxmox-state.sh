#!/usr/bin/env bash
set -euo pipefail

connection=${1:-}
if [[ -z "${connection}" ]]; then
	read -r -p "SSH root connection: " connection
fi

ssh_target=${connection#ssh://}
ssh_options=()
if [[ "${connection}" == ssh://* && "${ssh_target}" =~ ^(.+):([0-9]+)$ ]]; then
	ssh_target=${BASH_REMATCH[1]}
	ssh_options=(-p "${BASH_REMATCH[2]}")
fi

remote_report=$(ssh "${ssh_options[@]}" "${ssh_target}" 'bash -s' <<'EOF'
set -euo pipefail
print_value() {
	printf '%s\t%s\n' "$1" "$(printf '%s' "$2" | base64 -w0)"
}
print_value TS_PROXMOX_HOSTNAME "$(hostname -f)"
print_value PROXMOX_NODE "$(hostname -s)"
print_value PROXMOX_VERSION "$(pveversion --verbose | head -n 1)"
print_value OS_RELEASE "$(. /etc/os-release && printf '%s %s' "$PRETTY_NAME" "$VERSION_ID")"
print_value CPU "$(lscpu | awk -F: '/Model name/ {gsub(/^ +/, "", $2); print $2; exit}')"
print_value CPU_CORES "$(nproc)"
print_value MEMORY_MB "$(awk '/MemTotal/ {printf "%.0f", $2 / 1024}' /proc/meminfo)"
print_value NETWORK_ADDRESSES "$(ip -brief address)"
print_value NETWORK_LINKS "$(ip -brief link)"
print_value WOL "$(for interface in /sys/class/net/*; do name=${interface##*/}; [[ "$name" == lo ]] && continue; printf '%s: ' "$name"; ethtool "$name" 2>/dev/null | awk -F: '/Wake-on/ {gsub(/^ +/, "", $2); print $2}'; done)"
print_value STORAGE "$(pvesm status)"
print_value VMS "$(qm list)"
print_value PROXMOX_KNOWN_HOSTS "$(ssh-keyscan -H "$(hostname -f)" 2>/dev/null)"
EOF
)

declare -A values
while IFS=$'\t' read -r name encoded; do
	[[ -n "${name}" ]] || continue
	values["${name}"]=$(printf '%s' "${encoded}" | base64 -d)
done <<< "${remote_report}"

echo
echo "Proxmox current state"
for name in TS_PROXMOX_HOSTNAME PROXMOX_NODE PROXMOX_VERSION OS_RELEASE CPU CPU_CORES MEMORY_MB NETWORK_ADDRESSES NETWORK_LINKS WOL STORAGE VMS; do
	printf '%-22s %s\n' "${name}:" "${values[${name}]:-}"
done

read -r -p "Add this configuration to a GitHub repository with gh? [y/N]: " publish_answer
[[ "${publish_answer}" =~ ^[Yy]$ ]] || exit 0
command -v gh >/dev/null || { echo "gh CLI is required." >&2; exit 1; }
read -r -p "GitHub repository (OWNER/REPO): " repository
[[ -n "${repository}" ]] || { echo "Repository is required." >&2; exit 1; }

prompt_value() {
	local name=$1 prompt=$2 default=${3:-} value
	read -r -p "${prompt}${default:+ [${default}]}: " value
	printf -v "${name}" '%s' "${value:-${default}}"
}

prompt_value DOCKER_VM_ANSIBLE_TARGET_GROUP "Docker VM Ansible target group" docker_hosts
prompt_value DOCKER_VM_HOST_IP "Docker VM host IP"
prompt_value DOCKER_VM_TEMPLATE_ID "Docker VM template ID"
prompt_value DOCKER_VM_ID "Docker VM ID"
prompt_value DOCKER_VM_DATASTORE "Docker VM datastore"
prompt_value DOCKER_VM_IPV4_CIDR "Docker VM IPv4 CIDR" 24
prompt_value DOCKER_VM_IPV4_GATEWAY "Docker VM IPv4 gateway"
prompt_value DOCKER_VM_NETWORK_BRIDGE "Docker VM network bridge" vmbr0
prompt_value DOCKER_VM_DEPLOY_PATH "Docker VM deployment path" /opt/docker
prompt_value DOCKER_VM_DEPLOY_USER "Docker VM deployment user" deploy

variables=(TS_PROXMOX_HOSTNAME PROXMOX_NODE DOCKER_VM_ANSIBLE_TARGET_GROUP DOCKER_VM_HOST_IP DOCKER_VM_TEMPLATE_ID DOCKER_VM_ID DOCKER_VM_DATASTORE DOCKER_VM_IPV4_CIDR DOCKER_VM_IPV4_GATEWAY DOCKER_VM_NETWORK_BRIDGE DOCKER_VM_DEPLOY_PATH DOCKER_VM_DEPLOY_USER)
for name in "${variables[@]}"; do
	gh variable set "${name}" --repo "${repository}" --body "${!name:-${values[${name}]:-}}"
done

read -r -s -p "Tailscale OAuth client ID (leave blank to skip): " ts_client_id; echo
if [[ -n "${ts_client_id}" ]]; then
	read -r -s -p "Tailscale OAuth secret: " ts_secret; echo
	gh secret set TS_OAUTH_CLIENT_ID --repo "${repository}" --app actions --body "${ts_client_id}"
	gh secret set TS_OAUTH_SECRET --repo "${repository}" --app actions --body "${ts_secret}"
fi

read -r -p "Path to the VM SSH private key (leave blank to skip): " ssh_key_path
if [[ -n "${ssh_key_path}" ]]; then
	gh secret set PROXMOX_SSH_KEY --repo "${repository}" --app actions < "${ssh_key_path}"
fi
if [[ -n "${PVE_API_TOKEN_ID:-}" && -n "${PVE_API_TOKEN_SECRET:-}" ]]; then
	gh secret set PVE_API_TOKEN_ID --repo "${repository}" --app actions --body "${PVE_API_TOKEN_ID}"
	gh secret set PVE_API_TOKEN_SECRET --repo "${repository}" --app actions --body "${PVE_API_TOKEN_SECRET}"
else
	echo "Skipping Proxmox API token secrets because they were not provided."
fi
gh secret set PROXMOX_KNOWN_HOSTS --repo "${repository}" --app actions --body "${values[PROXMOX_KNOWN_HOSTS]}"

read -r -p "Docker VM known_hosts value (leave blank to skip): " docker_known_hosts
if [[ -n "${docker_known_hosts}" ]]; then
	gh secret set DOCKER_VM_KNOWN_HOSTS --repo "${repository}" --app actions --body "${docker_known_hosts}"
fi
echo "GitHub repository configuration updated: ${repository}"