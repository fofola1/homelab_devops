#!/usr/bin/env bash
# Persist Terraform state between GitHub Actions runs.
#
# The state is stored on a dedicated git branch instead of being uploaded as a
# workflow artifact. The state only contains infrastructure attributes (VM
# configuration and the cloud-init public key), never provider credentials.
#
# Usage: terraform-state.sh {restore|save}
set -euo pipefail

action=${1:-}
state_branch=${TERRAFORM_STATE_BRANCH:-terraform-state}
state_file=${TERRAFORM_STATE_FILE:-terraform/terraform.tfstate}
state_worktree=

cleanup() {
	if [[ -n "${state_worktree}" ]]; then
		git worktree remove --force "${state_worktree}" >/dev/null 2>&1 || rm -rf "${state_worktree}"
		git worktree prune >/dev/null 2>&1 || true
	fi
}
trap cleanup EXIT

fetch_state_branch() {
	git fetch --quiet --depth=1 origin "${state_branch}" 2>/dev/null
}

restore() {
	if ! fetch_state_branch; then
		echo "Terraform state branch '${state_branch}' does not exist yet; starting with an empty state."
		return 0
	fi

	if ! git cat-file -e "FETCH_HEAD:${state_file}" 2>/dev/null; then
		echo "State branch '${state_branch}' has no ${state_file}; starting with an empty state."
		return 0
	fi

	mkdir -p "$(dirname "${state_file}")"
	git show "FETCH_HEAD:${state_file}" > "${state_file}"
	echo "Restored ${state_file} from the '${state_branch}' branch."
}

save() {
	if [[ ! -s "${state_file}" ]]; then
		echo "No ${state_file} to persist."
		return 0
	fi

	state_worktree=$(mktemp -d)
	if fetch_state_branch; then
		git worktree add --quiet --detach "${state_worktree}" FETCH_HEAD
	else
		git worktree add --quiet --detach "${state_worktree}" HEAD
		git -C "${state_worktree}" checkout --quiet --orphan "${state_branch}"
		git -C "${state_worktree}" rm --quiet -rf . >/dev/null 2>&1 || true
	fi

	mkdir -p "${state_worktree}/$(dirname "${state_file}")"
	cp "${state_file}" "${state_worktree}/${state_file}"
	git -C "${state_worktree}" add "${state_file}"

	if git -C "${state_worktree}" diff --cached --quiet; then
		echo "Terraform state is unchanged."
		return 0
	fi

	git -C "${state_worktree}" \
		-c user.name="github-actions[bot]" \
		-c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
		commit --quiet -m "chore: update Terraform state"
	git -C "${state_worktree}" push --quiet origin "HEAD:${state_branch}"
	echo "Saved ${state_file} to the '${state_branch}' branch."
}

case "${action}" in
	restore)
		restore
		;;
	save)
		save
		;;
	*)
		echo "Usage: $0 {restore|save}" >&2
		exit 2
		;;
esac
