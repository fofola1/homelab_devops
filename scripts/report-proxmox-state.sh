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

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
config_file=$(cd -- "${script_directory}/.." && pwd)/report-proxmox-state.conf
[[ -f "${config_file}" ]] || {
	echo "Configuration file not found: ${config_file}" >&2
	exit 1
}
echo "Using configuration file: ${config_file}"
echo "Edit this file to fill in all required details before continuing."
read -r -p "Have you finished editing the configuration? [y/N]: " config_answer
[[ "${config_answer}" =~ ^[Yy]$ ]] || exit 0
# shellcheck disable=SC1090
source "${config_file}"

TS_PROXMOX_HOSTNAME=${TS_PROXMOX_HOSTNAME:-${values[TS_PROXMOX_HOSTNAME]:-}}
PROXMOX_NODE=${PROXMOX_NODE:-${values[PROXMOX_NODE]:-}}

for name in TS_PROXMOX_HOSTNAME PROXMOX_NODE DOCKER_VM_ANSIBLE_TARGET_GROUP \
	DOCKER_VM_HOST_IP DOCKER_VM_TEMPLATE_ID DOCKER_VM_ID DOCKER_VM_DATASTORE \
	DOCKER_VM_IPV4_CIDR DOCKER_VM_IPV4_GATEWAY DOCKER_VM_NETWORK_BRIDGE \
	DOCKER_VM_DEPLOY_PATH DOCKER_VM_DEPLOY_USER; do
	[[ -n "${!name:-}" ]] || { echo "${name} is required in ${config_file}." >&2; exit 1; }
done

read -r -p "GitHub repository (e.g. fofola1/homelab_devops or https://github.com/fofola1/homelab_devops): " repository_input
[[ -n "${repository_input}" ]] || { echo "Repository is required." >&2; exit 1; }
repository=${repository_input#https://github.com/}
repository=${repository#http://github.com/}
repository=${repository%/}
repository=${repository%.git}
if [[ "${repository}" != */* ]]; then
	repository="$(gh api user --jq .login)/${repository}"
fi
[[ "${repository}" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || {
	echo "Repository must be a GitHub URL, OWNER/REPO, or repository name." >&2
	exit 1
}

variables=(TS_PROXMOX_HOSTNAME PROXMOX_NODE DOCKER_VM_ANSIBLE_TARGET_GROUP DOCKER_VM_HOST_IP DOCKER_VM_TEMPLATE_ID DOCKER_VM_ID DOCKER_VM_DATASTORE DOCKER_VM_IPV4_CIDR DOCKER_VM_IPV4_GATEWAY DOCKER_VM_NETWORK_BRIDGE DOCKER_VM_DEPLOY_PATH DOCKER_VM_DEPLOY_USER)
for name in "${variables[@]}"; do
	gh variable set "${name}" --repo "${repository}" --body "${!name:-${values[${name}]:-}}"
done

if [[ -n "${TS_OAUTH_CLIENT_ID:-}" ]]; then
	gh secret set TS_OAUTH_CLIENT_ID --repo "${repository}" --app actions --body "${TS_OAUTH_CLIENT_ID}"
	[[ -n "${TS_OAUTH_SECRET:-}" ]] || { echo "TS_OAUTH_SECRET is required when TS_OAUTH_CLIENT_ID is set." >&2; exit 1; }
	gh secret set TS_OAUTH_SECRET --repo "${repository}" --app actions --body "${TS_OAUTH_SECRET}"
fi

if [[ -n "${PROXMOX_SSH_KEY_PATH:-}" ]]; then
	gh secret set PROXMOX_SSH_KEY --repo "${repository}" --app actions < "${PROXMOX_SSH_KEY_PATH}"
fi
if [[ -n "${PVE_API_TOKEN_ID:-}" && -n "${PVE_API_TOKEN_SECRET:-}" ]]; then
	gh secret set PVE_API_TOKEN_ID --repo "${repository}" --app actions --body "${PVE_API_TOKEN_ID}"
	gh secret set PVE_API_TOKEN_SECRET --repo "${repository}" --app actions --body "${PVE_API_TOKEN_SECRET}"
else
	echo "Skipping Proxmox API token secrets because they were not provided."
fi
gh secret set PROXMOX_KNOWN_HOSTS --repo "${repository}" --app actions --body "${values[PROXMOX_KNOWN_HOSTS]}"

if [[ -n "${DOCKER_VM_KNOWN_HOSTS:-}" ]]; then
	gh secret set DOCKER_VM_KNOWN_HOSTS --repo "${repository}" --app actions --body "${DOCKER_VM_KNOWN_HOSTS}"
fi
echo "GitHub repository configuration updated: ${repository}"