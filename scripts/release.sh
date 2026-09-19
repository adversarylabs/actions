#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repository="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
tag="${RELEASE_TAG:?RELEASE_TAG is required}"

# Publishing is downstream of the verified major-tag update, including reruns.
bash "$root/scripts/update-major-tag.sh"
major="${tag%%.*}"
release_commit="$(gh api -X GET "repos/$repository/commits/$tag" --jq .sha)"
major_commit="$(gh api -X GET "repos/$repository/commits/$major" --jq .sha)"
if [[ "$release_commit" != "$major_commit" ]]; then
  echo "$major does not point to $tag; refusing to publish." >&2
  exit 1
fi

if draft="$(gh release view "$tag" --repo "$repository" --json isDraft --jq .isDraft 2>/dev/null)"; then
  if [[ "$draft" == true ]]; then
    gh release edit "$tag" --repo "$repository" --draft=false
  fi
else
  gh release create "$tag" --repo "$repository" --verify-tag --title "$tag" --generate-notes
fi
