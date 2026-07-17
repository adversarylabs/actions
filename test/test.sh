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
grep -Fq 'install-dependencies:' "$root/publish/action.yml"
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

version=1.2.3
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
printf '%s  %s\n' "$checksum" "$archive" >"$release/checksums.txt"

runner="$tmp/runner"
mkdir -p "$runner"
github_path="$tmp/github-path"
INPUT_CLI_VERSION="$version" RUNNER_TEMP="$runner" GITHUB_PATH="$github_path" \
  ADVERSARY_DOWNLOAD_BASE="file://$release" bash "$root/publish/scripts/install.sh" >/dev/null
installed="$(tail -n 1 "$github_path")/adversary"
[[ -x "$installed" ]]
[[ "$("$installed" version)" == "adversary test-version" ]]

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
    ;;
  logout) [[ "$1" == --local-only ]] ;;
  validate) [[ "$1" == project ]] ;;
  pack) printf '%s\n' '{"schemaVersion":2,"command":"pack","data":{"canonicalReference":"example:1.0.0"}}' ;;
  push) printf '%s\n' '{"schemaVersion":1,"command":"push","data":{"canonicalReference":"registry.example/team/example:1.0.0","digest":"sha256:image","manifestDigest":"sha256:manifest"}}' ;;
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
