#!/usr/bin/env bash
set -euo pipefail

download() {
  local source="$1" output="$2"
  local args=(--fail --silent --show-error --location --retry 3 --retry-all-errors)
  if [[ "$source" == https://* ]]; then
    args+=(--proto '=https' --proto-redir '=https')
  fi
  # Authenticate GitHub requests when a token is available. Unauthenticated
  # calls to api.github.com share a low per-IP rate limit and intermittently
  # return HTTP 403 on hosted runners, which fails the latest-release lookup.
  local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [[ -n "$token" && ( "$source" == https://api.github.com/* || "$source" == https://github.com/* ) ]]; then
    args+=(--header "Authorization: Bearer ${token}")
  fi
  curl "${args[@]}" "$source" --output "$output"
}

version="${INPUT_CLI_VERSION:-}"
if [[ -z "$version" ]]; then
  latest_api="${ADVERSARY_LATEST_RELEASE_API:-https://api.github.com/repos/adversarylabs/adversary/releases/latest}"
  latest_metadata="${RUNNER_TEMP:?RUNNER_TEMP is required}/adversary-latest-release.json"
  if ! download "$latest_api" "$latest_metadata"; then
    echo "No stable Adversary CLI release could be resolved from GitHub. Set cli-version explicitly to use a prerelease." >&2
    exit 2
  fi
  if ! version="$(python3 - "$latest_metadata" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    release = json.load(stream)
tag = release.get("tag_name")
if release.get("draft") is not False or release.get("prerelease") is not False:
    raise SystemExit("GitHub's latest release response was not a stable release")
if not isinstance(tag, str) or not tag:
    raise SystemExit("GitHub's latest release response did not include tag_name")
print(tag)
PY
  )"; then
    echo "GitHub did not return a valid stable Adversary CLI release. Set cli-version explicitly to use a prerelease." >&2
    exit 2
  fi
  printf 'Resolved latest stable Adversary CLI release: %s\n' "$version"
fi

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]]; then
  echo "cli-version must be an exact release version, for example 2026.7.17-beta.3." >&2
  exit 2
fi

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) echo "The run action supports Linux and macOS runners." >&2; exit 2 ;;
esac

case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) echo "Unsupported runner architecture: $(uname -m)" >&2; exit 2 ;;
esac

archive="adversary_${version}_${os}_${arch}.tar.gz"
base="${ADVERSARY_DOWNLOAD_BASE:-https://github.com/adversarylabs/adversary/releases/download/${version}}"
install_dir="${RUNNER_TEMP:?RUNNER_TEMP is required}/adversary-cli-${version}"
download_dir="${RUNNER_TEMP}/adversary-download-${version}"
rm -rf -- "$install_dir" "$download_dir"
mkdir -p -- "$install_dir" "$download_dir"

download "${base}/${archive}" "${download_dir}/${archive}"
download "${base}/checksums.txt" "${download_dir}/checksums.txt"

expected="$(awk -v artifact="$archive" '
  $2 == artifact || $2 == ("*" artifact) { print tolower($1) }
  $1 == "SHA256" && $2 == ("(" artifact ")") && $3 == "=" { print tolower($4) }
' "${download_dir}/checksums.txt")"
if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
  echo "checksums.txt does not contain exactly one valid checksum for ${archive}." >&2
  exit 3
fi

if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "${download_dir}/${archive}" | awk '{print $1}')"
else
  actual="$(shasum -a 256 "${download_dir}/${archive}" | awk '{print $1}')"
fi
if [[ "$actual" != "$expected" ]]; then
  echo "Checksum verification failed for ${archive}." >&2
  exit 3
fi

tar -xzf "${download_dir}/${archive}" -C "$install_dir"
if [[ ! -f "${install_dir}/adversary" ]]; then
  echo "The verified release archive does not contain the adversary binary." >&2
  exit 3
fi
chmod +x "${install_dir}/adversary"
"${install_dir}/adversary" version
printf '%s\n' "$install_dir" >>"${GITHUB_PATH:?GITHUB_PATH is required}"
