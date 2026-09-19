#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) exit 1 ;; esac
case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; *) exit 1 ;; esac

for action in run push; do
  # Exercise the value the action runner supplies when cli-version is omitted.
  version="$(awk '/^  cli-version:/ { input = 1; next } input && /^    default:/ { print $2; exit }' "$root/$action/action.yml")"
  [[ -n "$version" ]]
  release="$tmp/$action/release"
  runner="$tmp/$action/runner"
  mkdir -p "$release/archive" "$runner"
  printf '#!/usr/bin/env bash\necho "doomer default-version fixture"\n' >"$release/archive/doomer"
  chmod +x "$release/archive/doomer"
  archive="doomer_${version}_${os}_${arch}.tar.gz"
  tar -czf "$release/$archive" -C "$release/archive" doomer
  if command -v sha256sum >/dev/null 2>&1; then
    checksum="$(sha256sum "$release/$archive" | awk '{print $1}')"
  else
    checksum="$(shasum -a 256 "$release/$archive" | awk '{print $1}')"
  fi
  printf '%s  %s\n' "$checksum" "$archive" >"$release/checksums.txt"
  github_path="$runner/github-path"
  INPUT_CLI_VERSION="$version" RUNNER_TEMP="$runner" GITHUB_PATH="$github_path" \
    ADVERSARY_DOWNLOAD_BASE="file://$release" \
    bash "$root/$action/scripts/install.sh" >"$runner/output"
  installed="$(tail -n 1 "$github_path")/doomer"
  [[ "$installed" == "$runner/doomer-cli-$version/doomer" ]]
  [[ "$("$installed" version)" == 'doomer default-version fixture' ]]

  for invalid in latest main 2026.9 2026.9.19.2 2026.9.19.2.1 2026.9.19. '../../outside'; do
    status=0
    INPUT_CLI_VERSION="$invalid" RUNNER_TEMP="$runner" GITHUB_PATH="$runner/github-path" \
      ADVERSARY_DOWNLOAD_BASE="file://$release" \
      bash "$root/$action/scripts/install.sh" >"$runner/output" 2>&1 || status=$?
    [[ "$status" == 2 ]]
    grep -Fq 'cli-version must be an exact release version' "$runner/output"
  done
done

echo "default CLI installer tests passed"
