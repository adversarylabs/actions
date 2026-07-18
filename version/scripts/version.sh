#!/usr/bin/env bash
set -euo pipefail

tag="${INPUT_TAG:?tag is required}"
project_path="${INPUT_PATH:-.}"
branch="${INPUT_BRANCH:-main}"
token="${INPUT_TOKEN:?token is required}"
sync_npm="${INPUT_SYNC_NPM:-auto}"
unset INPUT_TOKEN

case "$sync_npm" in
  auto|true|false) ;;
  *) echo "sync-npm must be auto, true, or false" >&2; exit 2 ;;
esac
if [[ "$tag" != v* ]]; then
  echo "tag must be v followed by a semantic version; got ${tag}." >&2
  exit 2
fi
version="${tag#v}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]]; then
  echo "tag must be v followed by a semantic version; got ${tag}." >&2
  exit 2
fi
if [[ "$project_path" == /* || "$project_path" == ".." || "$project_path" == ../* || "$project_path" == */../* || "$project_path" == */.. ]]; then
  echo "path must stay within the workspace" >&2
  exit 2
fi
if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
  echo "branch is not a valid Git branch name: ${branch}" >&2
  exit 2
fi

workspace="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
runner_temp="${RUNNER_TEMP:?RUNNER_TEMP is required}"
action_path="${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is required}"
output_path="${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
cd "$workspace"

metadata_output="$runner_temp/adversary-version-metadata"
node "$action_path/scripts/metadata.mjs" apply "$project_path" "$version" "$sync_npm" >"$metadata_output"
name="$(sed -n '1p' "$metadata_output")"
version_files=()
while IFS= read -r file; do
  [[ -n "$file" ]] && version_files[${#version_files[@]}]="$file"
done < <(sed -n '2,$p' "$metadata_output")
if [[ -z "$name" || ${#version_files[@]} -eq 0 ]]; then
  echo "release metadata did not return a name and version files" >&2
  exit 3
fi

echo "::add-mask::$token"
auth_header="$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')"
echo "::add-mask::$auth_header"
token=''
credential_key="http.https://github.com/.extraheader"
cleanup_credentials() {
  git config --local --unset-all "$credential_key" >/dev/null 2>&1 || true
}
trap cleanup_credentials EXIT
git config --local "$credential_key" "AUTHORIZATION: basic $auth_header"
auth_header=''

git fetch --no-tags origin "$branch"
tag_sha="$(git rev-parse "${GITHUB_SHA:?GITHUB_SHA is required}^{commit}")"
branch_sha="$(git rev-parse "origin/${branch}")"
message="chore: bump adversary version to ${version} [skip-ci]"
changed=false
commit="$branch_sha"

if [[ "$tag_sha" == "$branch_sha" ]]; then
  if git diff --quiet -- "${version_files[@]}"; then
    echo "Release metadata is already at ${version}; no bump commit is needed."
  else
    git config user.name "adversarylabs-release"
    git config user.email "adversarylabs-release@users.noreply.github.com"
    git add "${version_files[@]}"
    git commit -m "$message"
    commit="$(git rev-parse HEAD)"
    git push origin "HEAD:refs/heads/${branch}"
    changed=true
  fi
else
  if ! git merge-base --is-ancestor "$tag_sha" "origin/${branch}"; then
    echo "Release tag ${tag} no longer points at ${branch}." >&2
    exit 1
  fi
  if ! git log --format=%s "${tag_sha}..origin/${branch}" -- "${version_files[@]}" | grep -Fqx "$message"; then
    echo "The ${version} release metadata commit was not found on ${branch}." >&2
    exit 1
  fi

  verify_root="$runner_temp/adversary-version-main"
  rm -rf -- "$verify_root"
  mkdir -p -- "$verify_root"
  for file in "${version_files[@]}"; do
    mkdir -p -- "$verify_root/$(dirname "$file")"
    git show "origin/${branch}:${file}" >"$verify_root/$file"
  done
  node "$action_path/scripts/metadata.mjs" verify "$verify_root/$project_path" "$version" "$sync_npm" >/dev/null
  commit="$(git log -1 --format=%H --fixed-strings --grep="$message" "${tag_sha}..origin/${branch}" -- "${version_files[@]}")"
  echo "The ${version} release metadata bump is already on ${branch}; continuing this release rerun."
fi

cleanup_credentials
trap - EXIT

{
  printf 'name=%s\n' "$name"
  printf 'version=%s\n' "$version"
  printf 'changed=%s\n' "$changed"
  printf 'commit=%s\n' "$commit"
} >>"$output_path"
