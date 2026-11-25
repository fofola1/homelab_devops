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

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
infra_config_file=$(cd -- "${script_directory}/.." && pwd)/config/infra.yaml
[[ -f "${infra_config_file}" ]] || {
	echo "Infrastructure configuration file not found: ${infra_config_file}" >&2
	echo "Expected config/infra.yaml to be present in the repository." >&2
	exit 1
}
cloud_storage_image_datastore=$(sed -n 's/^[[:space:]]*image_datastore:[[:space:]]*"\([^"]*\)".*$/\1/p' "${infra_config_file}" | head -n 1)
[[ -n "${cloud_storage_image_datastore}" ]] || {
	echo "Unable to read image_datastore from ${infra_config_file}." >&2
	exit 1
}

remote_report=$(ssh "${ssh_options[@]}" "${ssh_target}" 'bash -s' <<'EOF'
set -euo pipefail
print_value() {
	printf '%s\t%s\n' "$1" "$(printf '%s' "$2" | base64 -w0)"
}
proxmox_hostname=$(hostname -f)
if command -v tailscale >/dev/null 2>&1; then
	tailscale_address=$(tailscale ip -4 2>/dev/null | head -n 1 || true)
	if [[ -n "${tailscale_address}" ]]; then
		proxmox_hostname=${tailscale_address}
	fi
fi
print_value TS_PROXMOX_HOSTNAME "${proxmox_hostname}"
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
print_value PROXMOX_KNOWN_HOSTS "$(ssh-keyscan -H "$(hostname -f)" "$(hostname -s)" 2>/dev/null | sort -u)"
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

report_config_file=$(cd -- "${script_directory}/.." && pwd)/report-proxmox-state.conf
[[ -f "${report_config_file}" ]] || {
	echo "Configuration file not found: ${report_config_file}" >&2
	echo "Copy report-proxmox-state.conf.example to report-proxmox-state.conf and fill it in." >&2
	exit 1
}
echo "Using configuration file: ${report_config_file}"

load_config() {
	local exported_client_id=${TS_OAUTH_CLIENT_ID:-}
	local exported_client_secret=${TS_OAUTH_SECRET:-}
	local exported_s3_url=${TF_STATE_S3_URL:-}
	local exported_s3_name=${TF_STATE_S3_NAME:-}
	local exported_s3_key_id=${TF_STATE_S3_KEY_ID:-}
	local exported_s3_key_secret=${TF_STATE_S3_KEY_SECRET:-}
	local exported_terraform_state_to_git=${TERRAFORM_STATE_TO_GIT:-}
	local exported_host_key_fingerprint=${PROXMOX_HOST_KEY_FINGERPRINT:-}
	local exported_proxmox_deploy_key=${GITHUB_PROXMOX_DEPLOY_KEY_PATH:-}
	local exported_cloud_storage_deploy_key=${GITHUB_CLOUD_STORAGE_DEPLOY_KEY_PATH:-}
	local exported_deploy_user=${PROXMOX_DEPLOY_USER:-}
	# shellcheck disable=SC1090
	source "${report_config_file}"
	TS_OAUTH_CLIENT_ID=${TS_OAUTH_CLIENT_ID:-${exported_client_id}}
	TS_OAUTH_SECRET=${TS_OAUTH_SECRET:-${exported_client_secret}}
	TF_STATE_S3_URL=${TF_STATE_S3_URL:-${exported_s3_url}}
	TF_STATE_S3_NAME=${TF_STATE_S3_NAME:-${exported_s3_name}}
	TF_STATE_S3_KEY_ID=${TF_STATE_S3_KEY_ID:-${exported_s3_key_id}}
	TF_STATE_S3_KEY_SECRET=${TF_STATE_S3_KEY_SECRET:-${exported_s3_key_secret}}
	TERRAFORM_STATE_TO_GIT=${TERRAFORM_STATE_TO_GIT:-${exported_terraform_state_to_git}}
	PROXMOX_HOST_KEY_FINGERPRINT=${PROXMOX_HOST_KEY_FINGERPRINT:-${exported_host_key_fingerprint}}
	GITHUB_PROXMOX_DEPLOY_KEY_PATH=${exported_proxmox_deploy_key:-${GITHUB_PROXMOX_DEPLOY_KEY_PATH:-}}
	GITHUB_CLOUD_STORAGE_DEPLOY_KEY_PATH=${exported_cloud_storage_deploy_key:-${GITHUB_CLOUD_STORAGE_DEPLOY_KEY_PATH:-}}
	PROXMOX_DEPLOY_USER=${exported_deploy_user:-${PROXMOX_DEPLOY_USER:-}}
	if [[ -z "${PROXMOX_DEPLOY_USER}" ]]; then
		PROXMOX_DEPLOY_USER=$(sed -n 's/^[[:space:]]*deploy_user:[[:space:]]*"\([^"]*\)".*$/\1/p' "${infra_config_file}" | head -n 1)
	fi
	TS_PROXMOX_HOSTNAME=${values[TS_PROXMOX_HOSTNAME]:-}
	PROXMOX_NODE=${values[PROXMOX_NODE]:-}
}

load_config

echo
echo "Effective GitHub configuration"
printf '%-32s %s\n' \
	TS_PROXMOX_HOSTNAME "${TS_PROXMOX_HOSTNAME}" \
	PROXMOX_HOST_KEY_FINGERPRINT "${PROXMOX_HOST_KEY_FINGERPRINT:-}" \
	TS_OAUTH_CLIENT_ID "${TS_OAUTH_CLIENT_ID:-}" \
	TS_OAUTH_SECRET "${TS_OAUTH_SECRET:+provided}" \
	PROXMOX_DEPLOY_USER "${PROXMOX_DEPLOY_USER:-}" \
	GITHUB_PROXMOX_DEPLOY_KEY_PATH "${GITHUB_PROXMOX_DEPLOY_KEY_PATH:-}" \
	GITHUB_CLOUD_STORAGE_DEPLOY_KEY_PATH "${GITHUB_CLOUD_STORAGE_DEPLOY_KEY_PATH:-}" \
	PVE_API_TOKEN_ID "${PVE_API_TOKEN_ID:+provided by prepare-proxmox.sh}" \
	PVE_API_TOKEN_SECRET "${PVE_API_TOKEN_SECRET:+provided by prepare-proxmox.sh}" \
	TF_STATE_S3_URL "${TF_STATE_S3_URL:-}" \
	TF_STATE_S3_NAME "${TF_STATE_S3_NAME:-}" \
	TERRAFORM_STATE_TO_GIT "${TERRAFORM_STATE_TO_GIT:-true}" \
	TF_STATE_S3_KEY_ID "${TF_STATE_S3_KEY_ID:+provided}" \
	TF_STATE_S3_KEY_SECRET "${TF_STATE_S3_KEY_SECRET:+provided}"

read -r -p "Add this configuration to a GitHub repository with gh? [y/N]: " publish_answer
[[ "${publish_answer}" =~ ^[Yy]$ ]] || exit 0
command -v gh >/dev/null || { echo "gh CLI is required." >&2; exit 1; }

echo "Edit ${report_config_file} to fill in all required details before continuing."
read -r -p "Have you finished editing the configuration? [y/N]: " config_answer
[[ "${config_answer}" =~ ^[Yy]$ ]] || exit 0
load_config

for name in TS_PROXMOX_HOSTNAME PROXMOX_NODE; do
	[[ -n "${!name}" ]] || { echo "Unable to discover ${name} from the Proxmox host." >&2; exit 1; }
done
for name in TS_OAUTH_CLIENT_ID TS_OAUTH_SECRET PROXMOX_DEPLOY_USER \
	GITHUB_PROXMOX_DEPLOY_KEY_PATH GITHUB_CLOUD_STORAGE_DEPLOY_KEY_PATH \
	PVE_API_TOKEN_ID PVE_API_TOKEN_SECRET; do
	[[ -n "${!name:-}" ]] || { echo "${name} is required for deployment." >&2; exit 1; }
done

temporary_ssh_key_directory=
cleanup_temporary_ssh_key() {
	if [[ -n "${temporary_ssh_key_directory}" ]]; then
		rm -rf "${temporary_ssh_key_directory}"
	fi
}
trap cleanup_temporary_ssh_key EXIT

prepare_deploy_key_file() {
	local requested_path=$1
	local default_name=$2
	local key_file=${requested_path}

	if [[ "${key_file}" == generate ]]; then
		if [[ -z "${temporary_ssh_key_directory}" ]]; then
			temporary_ssh_key_directory=$(mktemp --directory)
		fi
		key_file=${temporary_ssh_key_directory}/${default_name}
		ssh-keygen -q -t ed25519 -N '' -C "onprem ${default_name}" -f "${key_file}" || {
			rm -rf "${temporary_ssh_key_directory}"
			exit 1
		}
	elif [[ ! -f "${key_file}" ]]; then
		echo "SSH key file not found: ${key_file}" >&2
		exit 1
	fi

	key_file=$(cd -- "$(dirname -- "${key_file}")" && pwd)/$(basename -- "${key_file}")
	printf '%s' "${key_file}"
}

proxmox_deploy_key_file=$(prepare_deploy_key_file "${GITHUB_PROXMOX_DEPLOY_KEY_PATH}" "proxmox_deploy")
cloud_storage_deploy_key_file=$(prepare_deploy_key_file "${GITHUB_CLOUD_STORAGE_DEPLOY_KEY_PATH}" "cloud_storage_deploy")

ssh_host_only=${ssh_target#*@}
if ! ssh "${ssh_options[@]}" -i "${proxmox_deploy_key_file}" -o IdentitiesOnly=yes \
	-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-o "User=${PROXMOX_DEPLOY_USER}" "${ssh_host_only}" true; then
	echo "Unable to authenticate to ${PROXMOX_DEPLOY_USER}@${ssh_host_only} with the deployment key." >&2
	echo "Ensure ${PROXMOX_DEPLOY_USER} exists and the key is authorized." >&2
	echo "Running ./prepare-proxmox.sh configures this automatically." >&2
	exit 1
fi
echo "Verified the deployment key for ${PROXMOX_DEPLOY_USER} on ${ssh_host_only}."

storage_query_command="pvesh get /storage/${cloud_storage_image_datastore} --output-format json"
# shellcheck disable=SC2029
image_content=$(ssh "${ssh_options[@]}" "${ssh_target}" "${storage_query_command}" |
	sed -n 's/.*"content"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
[[ -n "${image_content}" ]] || {
	echo "Unable to read content types for Proxmox storage ${cloud_storage_image_datastore}." >&2
	exit 1
}
if [[ ",${image_content}," != *,import,* ]]; then
	storage_content_command="pvesm set ${cloud_storage_image_datastore} --content ${image_content},import"
	# shellcheck disable=SC2029
	ssh "${ssh_options[@]}" "${ssh_target}" \
		"${storage_content_command}"
fi

read -r -p "GitHub repository (e.g. fofola1/onprem_devops or https://github.com/fofola1/onprem_devops): " repository_input
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

gh variable set TS_PROXMOX_HOSTNAME --repo "${repository}" --body "${TS_PROXMOX_HOSTNAME}"
if [[ -n "${PROXMOX_HOST_KEY_FINGERPRINT:-}" ]]; then
	gh variable set PROXMOX_HOST_KEY_FINGERPRINT --repo "${repository}" --body "${PROXMOX_HOST_KEY_FINGERPRINT}"
fi
gh secret set TS_OAUTH_CLIENT_ID --repo "${repository}" --app actions --body "${TS_OAUTH_CLIENT_ID}"
gh secret set TS_OAUTH_SECRET --repo "${repository}" --app actions --body "${TS_OAUTH_SECRET}"
gh secret set PROXMOX_DEPLOY_SSH_KEY --repo "${repository}" --app actions < "${proxmox_deploy_key_file}"
gh secret set CLOUD_STORAGE_DEPLOY_SSH_KEY --repo "${repository}" --app actions < "${cloud_storage_deploy_key_file}"
gh secret set PVE_API_TOKEN_ID --repo "${repository}" --app actions --body "${PVE_API_TOKEN_ID}"
gh secret set PVE_API_TOKEN_SECRET --repo "${repository}" --app actions --body "${PVE_API_TOKEN_SECRET}"
gh secret set PVE_API_TOKEN --repo "${repository}" --app actions \
	--body "${PVE_API_TOKEN_ID}=${PVE_API_TOKEN_SECRET}"
gh secret set PROXMOX_KNOWN_HOSTS --repo "${repository}" --app actions --body "${values[PROXMOX_KNOWN_HOSTS]}"

if [[ -n "${TF_STATE_S3_URL:-}" ]]; then
	gh variable set TF_STATE_S3_URL --repo "${repository}" --body "${TF_STATE_S3_URL}"
	gh variable set TF_STATE_S3_NAME --repo "${repository}" --body "${TF_STATE_S3_NAME:-}"
	gh secret set TF_STATE_S3_KEY_ID --repo "${repository}" --app actions --body "${TF_STATE_S3_KEY_ID}"
	gh secret set TF_STATE_S3_KEY_SECRET --repo "${repository}" --app actions --body "${TF_STATE_S3_KEY_SECRET}"
	gh variable set TERRAFORM_STATE_TO_GIT --repo "${repository}" --body "${TERRAFORM_STATE_TO_GIT:-true}"
fi
echo "GitHub repository configuration updated: ${repository}"
