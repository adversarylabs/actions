#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bash -n "$root/publish/scripts/install.sh"
bash -n "$root/publish/scripts/package.sh"
bash -n "$root/publish/scripts/push.sh"
grep -Fq 'using: composite' "$root/publish/action.yml"
grep -Fq 'cli-version:' "$root/publish/action.yml"
cli_version_input="$(sed -n '/^  cli-version:/,/^  path:/p' "$root/publish/action.yml")"
grep -Fq 'required: false' <<<"$cli_version_input"
if grep -Fq 'required: true' <<<"$cli_version_input"; then
  echo "cli-version is still required" >&2
  exit 1
fi
grep -Fq 'install-dependencies:' "$root/publish/action.yml"
grep -Fq 'repository-name:' "$root/publish/action.yml"
grep -Fq 'publish-latest:' "$root/publish/action.yml"
grep -Fq 'auth-mode:' "$root/publish/action.yml"
grep -Fq 'token:' "$root/publish/action.yml"
if grep -Eq 'email-address:|INPUT_EMAIL_ADDRESS|password:|INPUT_PASSWORD' "$root/publish/action.yml"; then
  echo "action metadata still exposes password authentication" >&2
  exit 1
fi
package_step="$(sed -n '/- name: Validate and package/,/- name: Authenticate and publish/p' "$root/publish/action.yml")"
if grep -Eq 'INPUT_AUTH_MODE|INPUT_TOKEN' <<<"$package_step"; then
  echo "action metadata mixes authentication into the package step" >&2
  exit 1
fi

case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) echo "unsupported test OS" >&2; exit 1 ;; esac
case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; *) echo "unsupported test architecture" >&2; exit 1 ;; esac

version=1.2.3-rc-1+build.5
release="$tmp/release"
mkdir -p "$release/archive"
printf '#!/usr/bin/env bash\necho "adversary test-version"\n' >"$release/archive/adversary"
chmod +x "$release/archive/adversary"
archive="adversary_${version}_${os}_${arch}.tar.gz"
tar -czf "$release/$archive" -C "$release/archive" adversary
if command -v sha256sum >/dev/null 2>&1; then
  checksum="$(sha256sum "$release/$archive" | awk '{print $1}')"
else
  checksum="$(shasum -a 256 "$release/$archive" | awk '{print $1}')"
fi
printf '%s *%s\n' "$checksum" "$archive" >"$release/checksums.txt"

runner="$tmp/runner"
mkdir -p "$runner"
github_path="$tmp/github-path"
INPUT_CLI_VERSION="$version" RUNNER_TEMP="$runner" GITHUB_PATH="$github_path" \
  ADVERSARY_DOWNLOAD_BASE="file://$release" bash "$root/publish/scripts/install.sh" >/dev/null
installed="$(tail -n 1 "$github_path")/adversary"
[[ -x "$installed" ]]
[[ "$("$installed" version)" == "adversary test-version" ]]

printf 'SHA256 (%s) = %s\n' "$archive" "$checksum" >"$release/checksums.txt"
INPUT_CLI_VERSION="$version" RUNNER_TEMP="$runner" GITHUB_PATH="$github_path" \
  ADVERSARY_DOWNLOAD_BASE="file://$release" bash "$root/publish/scripts/install.sh" >/dev/null

latest_metadata="$tmp/latest-release.json"
printf '{"tag_name":"%s","draft":false,"prerelease":false}\n' "$version" >"$latest_metadata"
latest_output="$tmp/latest-output"
INPUT_CLI_VERSION='' RUNNER_TEMP="$runner" GITHUB_PATH="$github_path" \
  ADVERSARY_LATEST_RELEASE_API="file://$latest_metadata" ADVERSARY_DOWNLOAD_BASE="file://$release" \
  bash "$root/publish/scripts/install.sh" >"$latest_output"
grep -Fq "Resolved latest stable Adversary CLI release: $version" "$latest_output"
installed="$(tail -n 1 "$github_path")/adversary"
[[ -x "$installed" ]]

prerelease_metadata="$tmp/prerelease.json"
printf '{"tag_name":"%s","draft":false,"prerelease":true}\n' "$version" >"$prerelease_metadata"
if INPUT_CLI_VERSION='' RUNNER_TEMP="$runner" GITHUB_PATH="$github_path" \
  ADVERSARY_LATEST_RELEASE_API="file://$prerelease_metadata" ADVERSARY_DOWNLOAD_BASE="file://$release" \
  bash "$root/publish/scripts/install.sh" >"$tmp/prerelease-stdout" 2>"$tmp/prerelease-stderr"; then
  echo "installer selected a prerelease as the latest stable CLI" >&2
  exit 1
fi
grep -Fq 'Set cli-version explicitly to use a prerelease.' "$tmp/prerelease-stderr"

if INPUT_CLI_VERSION=latest RUNNER_TEMP="$runner" GITHUB_PATH="$github_path" \
  ADVERSARY_DOWNLOAD_BASE="file://$release" bash "$root/publish/scripts/install.sh" >/dev/null 2>&1; then
  echo "installer accepted a mutable CLI version" >&2
  exit 1
fi

printf '%064d  %s\n' 0 "$archive" >"$release/checksums.txt"
if INPUT_CLI_VERSION="$version" RUNNER_TEMP="$runner" GITHUB_PATH="$github_path" \
  ADVERSARY_DOWNLOAD_BASE="file://$release" bash "$root/publish/scripts/install.sh" >/dev/null 2>&1; then
  echo "installer accepted a checksum mismatch" >&2
  exit 1
fi

fake_bin="$tmp/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/adversary" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
profile=default
if [[ "${1:-}" == --profile ]]; then profile="$2"; shift 2; fi
command="$1"; shift
if [[ -n "${INPUT_TOKEN:-}" ]]; then
  echo "$command received the service account token in its environment" >&2
  exit 88
fi
printf '%s profile=%s args=%s\n' "$command" "$profile" "$*" >>"$FAKE_LOG"
case "$command" in
  login)
    if [[ "$*" == '--token-stdin --registry-namespace adversarylabs' ]]; then
      IFS= read -r supplied
      [[ "$supplied" == "$EXPECTED_TOKEN" ]]
    else
      [[ "$*" == '--ci --name GitHub Actions' ]]
    fi
    if [[ "${FAIL_LOGIN:-false}" == true ]]; then exit 7; fi
    ;;
  logout) [[ "$1" == --local-only ]] ;;
  validate) [[ "$1" == project || "$1" == project-pnpm ]] ;;
  pack) printf '%s\n' '{"schemaVersion":2,"command":"pack","data":{"canonicalReference":"example:1.0.0"}}' ;;
  push)
    reference="$2"
    printf '{"schemaVersion":1,"command":"push","data":{"canonicalReference":"%s","digest":"sha256:image","manifestDigest":"sha256:manifest"}}\n' "$reference"
    ;;
  *) echo "unexpected command: $command" >&2; exit 9 ;;
esac
FAKE
chmod +x "$fake_bin/adversary"

cat >"$fake_bin/npm" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'npm args=%s\n' "$*" >>"$FAKE_LOG"
FAKE
chmod +x "$fake_bin/npm"

mkdir -p "$tmp/work/project"
touch "$tmp/work/project/package-lock.json"
package_output="$tmp/package-output"
push_output="$tmp/push-output"
log="$tmp/fake.log"

PATH="$fake_bin:$PATH" FAKE_LOG="$log" RUNNER_TEMP="$runner" GITHUB_OUTPUT="$package_output" \
  INPUT_PATH=project INPUT_BUILDER=local INPUT_INSTALL_DEPENDENCIES=true INPUT_NAME='' \
  bash -c 'cd "$1" && bash "$2"' _ "$tmp/work" "$root/publish/scripts/package.sh"

grep -Fq 'validate profile=default args=project' "$log"
grep -Fq 'npm args=ci' "$log"
grep -Fq 'pack profile=default args=project --builder local --format json' "$log"
grep -Fq 'local-reference=example:1.0.0' "$package_output"

mkdir -p "$tmp/work/project-pnpm" "$tmp/no-corepack-bin"
touch "$tmp/work/project-pnpm/pnpm-lock.yaml"
ln -s "$(command -v bash)" "$tmp/no-corepack-bin/bash"
if PATH="$fake_bin:$tmp/no-corepack-bin" FAKE_LOG="$log" RUNNER_TEMP="$runner" GITHUB_OUTPUT="$package_output" \
  INPUT_PATH=project-pnpm INPUT_BUILDER=local INPUT_INSTALL_DEPENDENCIES=true INPUT_NAME='' \
  "$tmp/no-corepack-bin/bash" -c 'cd "$1" && bash "$2"' _ "$tmp/work" "$root/publish/scripts/package.sh" \
  >"$tmp/corepack-stdout" 2>"$tmp/corepack-stderr"; then
  echo "package install accepted pnpm without Corepack" >&2
  exit 1
fi
grep -Fq 'Installing pnpm dependencies requires Corepack.' "$tmp/corepack-stderr"

PATH="$fake_bin:$PATH" FAKE_LOG="$log" EXPECTED_TOKEN='adv_sa_do-not-print-me' \
  RUNNER_TEMP="$runner" GITHUB_OUTPUT="$push_output" \
  INPUT_LOCAL_REFERENCE=example:1.0.0 INPUT_PROFILE=release INPUT_API_URL=https://api.example \
  INPUT_AUTH_MODE=token INPUT_TOKEN='adv_sa_do-not-print-me' INPUT_CLIENT_NAME='GitHub Actions' \
  INPUT_REMOTE_REFERENCE=registry.example/team/example:1.0.0 \
  INPUT_REGISTRY_HOST='' INPUT_REGISTRY_NAMESPACE=adversarylabs \
  bash "$root/publish/scripts/push.sh" >"$tmp/publish-stdout"

grep -Fq 'login profile=release args=--token-stdin --registry-namespace adversarylabs' "$log"
grep -Fq 'push profile=release args=example:1.0.0 registry.example/team/example:1.0.0 --format json' "$log"
grep -Fq 'logout profile=release args=--local-only' "$log"
grep -Fq 'reference=registry.example/team/example:1.0.0' "$push_output"
grep -Fq 'digest=sha256:image' "$push_output"
grep -Fq 'manifest-digest=sha256:manifest' "$push_output"
if grep -Fq 'adv_sa_do-not-print-me' "$log" "$tmp/publish-stdout" "$package_output" "$push_output"; then
  echo "service account token leaked into action output" >&2
  exit 1
fi

named_log="$tmp/named.log"
named_output="$tmp/named-output"
PATH="$fake_bin:$PATH" FAKE_LOG="$named_log" EXPECTED_TOKEN='adv_sa_do-not-print-me' \
  RUNNER_TEMP="$runner" GITHUB_OUTPUT="$named_output" \
  INPUT_LOCAL_REFERENCE=registry.adversarylabs.ai/library/depotci:0.0.3 INPUT_PROFILE=release \
  INPUT_API_URL=https://api.example INPUT_AUTH_MODE=token INPUT_TOKEN='adv_sa_do-not-print-me' \
  INPUT_CLIENT_NAME='GitHub Actions' INPUT_REMOTE_REFERENCE='' INPUT_REPOSITORY_NAME=depotci-adversary \
  INPUT_PUBLISH_LATEST=true INPUT_REGISTRY_HOST='' INPUT_REGISTRY_NAMESPACE=adversarylabs \
  bash "$root/publish/scripts/push.sh" >/dev/null
grep -Fq 'push profile=release args=registry.adversarylabs.ai/library/depotci:0.0.3 registry.adversarylabs.ai/adversarylabs/depotci-adversary:0.0.3 --format json' "$named_log"
grep -Fq 'push profile=release args=registry.adversarylabs.ai/library/depotci:0.0.3 registry.adversarylabs.ai/adversarylabs/depotci-adversary:latest --format json' "$named_log"
grep -Fq 'reference=registry.adversarylabs.ai/adversarylabs/depotci-adversary:0.0.3' "$named_output"
grep -Fq 'latest-reference=registry.adversarylabs.ai/adversarylabs/depotci-adversary:latest' "$named_output"

if PATH="$fake_bin:$PATH" RUNNER_TEMP="$runner" GITHUB_OUTPUT="$named_output" \
  INPUT_LOCAL_REFERENCE=example:1.0.0 INPUT_AUTH_MODE=existing INPUT_TOKEN='' \
  INPUT_REMOTE_REFERENCE=registry.example/team/example:1.0.0 INPUT_REPOSITORY_NAME=example \
  INPUT_PUBLISH_LATEST=false INPUT_REGISTRY_NAMESPACE=team \
  bash "$root/publish/scripts/push.sh" >/dev/null 2>&1; then
  echo "publish accepted both remote-reference and repository-name" >&2
  exit 1
fi

if PATH="$fake_bin:$PATH" RUNNER_TEMP="$runner" GITHUB_OUTPUT="$named_output" \
  INPUT_LOCAL_REFERENCE=example:1.0.0 INPUT_AUTH_MODE=existing INPUT_TOKEN='' \
  INPUT_REMOTE_REFERENCE=registry.example/team/example:1.0.0 INPUT_REPOSITORY_NAME='' \
  INPUT_PUBLISH_LATEST=maybe INPUT_REGISTRY_NAMESPACE=team \
  bash "$root/publish/scripts/push.sh" >/dev/null 2>&1; then
  echo "publish accepted an invalid publish-latest value" >&2
  exit 1
fi

existing_log="$tmp/existing.log"
existing_output="$tmp/existing-output"
PATH="$fake_bin:$PATH" FAKE_LOG="$existing_log" RUNNER_TEMP="$runner" GITHUB_OUTPUT="$existing_output" \
  INPUT_LOCAL_REFERENCE=example:1.0.0 INPUT_PROFILE='' INPUT_API_URL=https://api.example \
  INPUT_AUTH_MODE=existing INPUT_TOKEN='' INPUT_CLIENT_NAME='GitHub Actions' \
  INPUT_REMOTE_REFERENCE=registry.example/team/example:1.0.0 \
  INPUT_REGISTRY_HOST='' INPUT_REGISTRY_NAMESPACE='' \
  bash "$root/publish/scripts/push.sh" >/dev/null
grep -Fq 'push profile=default args=example:1.0.0 registry.example/team/example:1.0.0 --format json' "$existing_log"
if grep -Eq '^(login|logout) ' "$existing_log"; then
  echo "existing authentication unexpectedly changed CLI login state" >&2
  exit 1
fi

explicit_profile_log="$tmp/explicit-profile.log"
PATH="$fake_bin:$PATH" FAKE_LOG="$explicit_profile_log" RUNNER_TEMP="$runner" GITHUB_OUTPUT="$existing_output" \
  INPUT_LOCAL_REFERENCE=example:1.0.0 INPUT_PROFILE=preconfigured INPUT_API_URL=https://api.example \
  INPUT_AUTH_MODE=existing INPUT_TOKEN='' INPUT_CLIENT_NAME='GitHub Actions' \
  INPUT_REMOTE_REFERENCE=registry.example/team/example:1.0.0 \
  INPUT_REGISTRY_HOST='' INPUT_REGISTRY_NAMESPACE='' \
  bash "$root/publish/scripts/push.sh" >/dev/null
grep -Fq 'push profile=preconfigured args=example:1.0.0 registry.example/team/example:1.0.0 --format json' "$explicit_profile_log"

failed_login_log="$tmp/failed-login.log"
if PATH="$fake_bin:$PATH" FAKE_LOG="$failed_login_log" EXPECTED_TOKEN='adv_sa_do-not-print-me' FAIL_LOGIN=true \
  RUNNER_TEMP="$runner" GITHUB_OUTPUT="$push_output" \
  INPUT_LOCAL_REFERENCE=example:1.0.0 INPUT_PROFILE=release INPUT_API_URL=https://api.example \
  INPUT_AUTH_MODE=token INPUT_TOKEN='adv_sa_do-not-print-me' INPUT_CLIENT_NAME='GitHub Actions' \
  INPUT_REMOTE_REFERENCE=registry.example/team/example:1.0.0 \
  INPUT_REGISTRY_HOST='' INPUT_REGISTRY_NAMESPACE=adversarylabs \
  bash "$root/publish/scripts/push.sh" >"$tmp/failed-login-output" 2>&1; then
  echo "publish continued after a failed login" >&2
  exit 1
fi
grep -Fq 'login profile=release args=--token-stdin --registry-namespace adversarylabs' "$failed_login_log"
grep -Fq 'logout profile=release args=--local-only' "$failed_login_log"
if grep -Fq 'adv_sa_do-not-print-me' "$failed_login_log" "$tmp/failed-login-output"; then
  echo "failed login leaked the service account token" >&2
  exit 1
fi

if PATH="$fake_bin:$PATH" RUNNER_TEMP="$runner" GITHUB_OUTPUT="$push_output" \
  INPUT_LOCAL_REFERENCE=example:1.0.0 INPUT_AUTH_MODE=invalid \
  bash "$root/publish/scripts/push.sh" >/dev/null 2>&1; then
  echo "publish accepted an invalid auth mode" >&2
  exit 1
fi

if PATH="$fake_bin:$PATH" RUNNER_TEMP="$runner" GITHUB_OUTPUT="$push_output" \
  INPUT_LOCAL_REFERENCE=example:1.0.0 INPUT_AUTH_MODE=token INPUT_TOKEN='' \
  INPUT_REGISTRY_NAMESPACE=adversarylabs bash "$root/publish/scripts/push.sh" >/dev/null 2>&1; then
  echo "publish accepted token authentication without a token" >&2
  exit 1
fi

echo "publish action tests passed"
bash "$root/test/version.sh"
