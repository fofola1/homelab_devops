#!/usr/bin/env bash
# Build a known_hosts file for the Proxmox host and any extra hosts.
#
# The PROXMOX_KNOWN_HOSTS secret is used as the base trust store. Fresh keys
# obtained with ssh-keyscan are appended as well, so a rotated Proxmox host key
# does not block every deployment. This is equivalent to accepting a new host
# key on first use for the affected host.
#
# Set PROXMOX_HOST_KEY_FINGERPRINT to pin a fingerprint (for example the output
# of "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub") and fail when the
# discovered keys do not match it.
#
# Usage: proxmox-known-hosts.sh <hostname> <output-file> [extra-host ...]
set -euo pipefail

if [[ $# -lt 2 ]]; then
	echo "Usage: $0 <hostname> <output-file> [extra-host ...]" >&2
	exit 2
fi

hostname=$1
output_file=$2
shift 2
extra_hosts=("$@")

mkdir -p "$(dirname "${output_file}")"
: > "${output_file}"

if [[ -n "${PROXMOX_KNOWN_HOSTS:-}" ]]; then
	printf '%s\n' "${PROXMOX_KNOWN_HOSTS}" >> "${output_file}"
fi

hosts=("${hostname}")
if [[ ${#extra_hosts[@]} -gt 0 ]]; then
	hosts+=("${extra_hosts[@]}")
fi

for host in "${hosts[@]}"; do
	if ! ssh-keyscan -T 10 -H "${host}" >> "${output_file}" 2>/dev/null; then
		echo "Warning: ssh-keyscan could not retrieve host keys for ${host}." >&2
	fi
done

if [[ ! -s "${output_file}" ]]; then
	echo "Unable to discover SSH host keys for ${hostname}." >&2
	exit 1
fi

if [[ -n "${PROXMOX_HOST_KEY_FINGERPRINT:-}" ]]; then
	if ! ssh-keygen -lf "${output_file}" | awk '{ print $2 }' | grep -qxF "${PROXMOX_HOST_KEY_FINGERPRINT}"; then
		echo "The discovered host keys do not include the pinned fingerprint ${PROXMOX_HOST_KEY_FINGERPRINT}." >&2
		echo "Discovered fingerprints:" >&2
		ssh-keygen -lf "${output_file}" >&2
		exit 1
	fi
fi

echo "SSH host keys for ${hostname}:"
ssh-keygen -lf "${output_file}" | awk '{ printf "  %s %s\n", $2, $4 }'
