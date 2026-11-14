#!/usr/bin/env bash
# Select whole disks for the ZFS pool and publish them to GitHub repository variables.
#
# The selector lists the whole disks visible on this machine and asks which ones
# should back the pool. The selection is written to the ZFS_POOL_DRIVES repository
# variable as a comma-separated device list; ZFS_POOL_RAID_LEVEL records the RAID
# level. The CD pipeline then runs the Ansible host stage, which creates the pool
# before Terraform plans the VM disk.
#
# Usage: create-raid-pool.sh [repository]

set -euo pipefail

repository=${1:-fofola1/homelab_devops}

die() {
	echo "create-raid-pool.sh: $*" >&2
	exit 1
}

command -v gh >/dev/null 2>&1 || die "gh CLI is required."
command -v lsblk >/dev/null 2>&1 || die "lsblk is required."

mapfile -t disk_list < <(lsblk -d -o NAME,SIZE 2>/dev/null | tail -n +2)

if [[ ${#disk_list[@]} -eq 0 ]]; then
	die "No whole disks found on this machine."
fi

echo "Available whole disks:"
index=1
for drive in "${disk_list[@]}"; do
	printf '  %d) %s\n' "${index}" "${drive}"
	index=$((index + 1))
done

read -r -p "Select disk indices for the ZFS pool (comma-separated): " selection
[[ "${selection}" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "Selection must be comma-separated numbers, for example 1,2,3."

IFS=',' read -r -a chosen <<< "${selection}"
disks=()
for idx in "${chosen[@]}"; do
	drive="${disk_list[$((10#$idx - 1))]}"
	read -r -a drive_parts <<< "${drive}"
	disks+=("/dev/${drive_parts[0]}")
done

if [[ ${#disks[@]} -eq 0 ]]; then
	die "No valid disks selected."
fi

drives_csv=$(IFS=,; printf '%s' "${disks[*]}")
gh variable set ZFS_POOL_DRIVES --repo "${repository}" --body "${drives_csv}"
gh variable set ZFS_POOL_RAID_LEVEL --repo "${repository}" --body "raidz1"

echo "Published ZFS_POOL_DRIVES=${drives_csv}"
echo "Published ZFS_POOL_RAID_LEVEL=raidz1"
echo "Run the CD deployment to create the ZFS pool."
