#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${repo_root}"

source_directories=(terraform ansible docker)

for directory in "${source_directories[@]}"; do
	test -d "${directory}"

	mapfile -t files < <(
		find "${directory}" \
			-type d -name .terraform -prune -o \
			-type f -print
	)

	test "${#files[@]}" -gt 0
	printf 'Found %d relevant file(s) in %s\n' "${#files[@]}" "${directory}"
done