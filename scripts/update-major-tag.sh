#!/usr/bin/env bash
set -euo pipefail

repository="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
release_tag="${RELEASE_TAG:?RELEASE_TAG is required}"

if [[ ! "$release_tag" =~ ^v([0-9]+)\.[0-9]+\.[0-9]+$ ]]; then
  echo "Stable action release tags must match vMAJOR.MINOR.PATCH: $release_tag" >&2
  exit 1
fi

major_tag="v${BASH_REMATCH[1]}"
latest_tag=""
while IFS= read -r ref; do
  candidate="${ref#refs/tags/}"
  if [[ ! "$candidate" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    continue
  fi

  candidate_version=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")
  if [[ -z "$latest_tag" ]]; then
    latest_tag="$candidate"
    latest_version=("${candidate_version[@]}")
    continue
  fi

  for index in 0 1 2; do
    if ((10#${candidate_version[$index]} > 10#${latest_version[$index]})); then
      latest_tag="$candidate"
      latest_version=("${candidate_version[@]}")
      break
    fi
    if ((10#${candidate_version[$index]} < 10#${latest_version[$index]})); then
      break
    fi
  done
done < <(gh api --paginate "repos/${repository}/git/matching-refs/tags/${major_tag}." --jq '.[].ref')

if [[ -z "$latest_tag" ]]; then
  echo "GitHub did not return any stable ${major_tag}.x.x tags." >&2
  exit 1
fi
if [[ "$release_tag" != "$latest_tag" ]]; then
  printf 'Skipping %s because %s is the latest stable tag.\n' "$release_tag" "$latest_tag"
  exit 0
fi

release_commit="$(gh api -X GET "repos/${repository}/commits/${release_tag}" --jq .sha)"
if [[ ! "$release_commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "GitHub did not resolve $release_tag to a full commit SHA." >&2
  exit 1
fi

if gh api -X GET "repos/${repository}/git/ref/tags/${major_tag}" >/dev/null 2>&1; then
  gh api -X PATCH "repos/${repository}/git/refs/tags/${major_tag}" \
    -f sha="$release_commit" -F force=true >/dev/null
  verb=Updated
else
  gh api -X POST "repos/${repository}/git/refs" \
    -f ref="refs/tags/${major_tag}" -f sha="$release_commit" >/dev/null
  verb=Created
fi

actual_commit="$(gh api -X GET "repos/${repository}/commits/${major_tag}" --jq .sha)"
if [[ "$actual_commit" != "$release_commit" ]]; then
  echo "$major_tag resolved to $actual_commit instead of $release_commit after the update." >&2
  exit 1
fi

printf '%s %s at %s (%s).\n' "$verb" "$major_tag" "$release_commit" "$release_tag"
