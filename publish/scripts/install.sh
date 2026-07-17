#!/usr/bin/env bash
set -euo pipefail

version="${INPUT_CLI_VERSION:?cli-version is required}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]]; then
  echo "cli-version must be an exact release version, for example 2026.7.9-beta.1." >&2
  exit 2
fi

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) echo "The publish action supports Linux and macOS runners." >&2; exit 2 ;;
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

curl_args=(--fail --silent --show-error --location --retry 3 --retry-all-errors)
if [[ "$base" == https://* ]]; then
  curl_args+=(--proto '=https' --proto-redir '=https')
fi
curl "${curl_args[@]}" "${base}/${archive}" --output "${download_dir}/${archive}"
curl "${curl_args[@]}" "${base}/checksums.txt" --output "${download_dir}/checksums.txt"

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
