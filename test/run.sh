#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bash -n "$root/run/scripts/install.sh"
bash -n "$root/run/scripts/run.sh"
grep -Fq 'name: Run Adversary' "$root/run/action.yml"
grep -Fq 'using: composite' "$root/run/action.yml"
grep -Fq 'adversaries:' "$root/run/action.yml"
adversaries_input="$(sed -n '/^  adversaries:/,/^  cli-version:/p' "$root/run/action.yml")"
grep -Fq 'required: false' <<<"$adversaries_input"
grep -Fq 'default: auto' <<<"$adversaries_input"
if grep -Fq 'required: true' <<<"$adversaries_input"; then
  echo "adversaries is still required" >&2
  exit 1
fi
grep -Fq 'model-provider:' "$root/run/action.yml"
grep -Fq 'model-api-key:' "$root/run/action.yml"
grep -Fq 'auth-mode:' "$root/run/action.yml"
grep -Fq 'token:' "$root/run/action.yml"
grep -Fq 'fail-on-findings:' "$root/run/action.yml"
path_input="$(sed -n '/^  path:/,/^  base:/p' "$root/run/action.yml")"
grep -Fq 'default: .' <<<"$path_input"
auth_input="$(sed -n '/^  auth-mode:/,/^  token:/p' "$root/run/action.yml")"
grep -Fq 'default: none' <<<"$auth_input"
if grep -Eq 'email-address:|INPUT_EMAIL_ADDRESS|password:|INPUT_PASSWORD' "$root/run/action.yml"; then
  echo "run action metadata still exposes password authentication" >&2
  exit 1
fi
install_step="$(sed -n '/- name: Install Adversary CLI/,/- name: Authenticate and run/p' "$root/run/action.yml")"
if grep -Eq 'INPUT_TOKEN|INPUT_MODEL_API_KEY|INPUT_AUTH_MODE' <<<"$install_step"; then
  echo "run action metadata mixes secrets into the install step" >&2
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
  ADVERSARY_DOWNLOAD_BASE="file://$release" bash "$root/run/scripts/install.sh" >/dev/null
installed="$(tail -n 1 "$github_path")/adversary"
[[ -x "$installed" ]]
[[ "$("$installed" version)" == "adversary test-version" ]]

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
if [[ -n "${INPUT_MODEL_API_KEY:-}" ]]; then
  echo "$command received the model API key input in its environment" >&2
  exit 88
fi
printf '%s profile=%s args=%s\n' "$command" "$profile" "$*" >>"$FAKE_LOG"
printf 'env OPENAI_API_KEY=%s ANTHROPIC_API_KEY=%s FIREWORKS_API_KEY=%s ADVERSARY_MODEL_PROVIDER=%s\n' \
  "${OPENAI_API_KEY:-}" "${ANTHROPIC_API_KEY:-}" "${FIREWORKS_API_KEY:-}" "${ADVERSARY_MODEL_PROVIDER:-}" >>"$FAKE_LOG"
case "$command" in
  login)
    if [[ "$*" == '--token-stdin --registry-namespace adversarylabs' ]]; then
      IFS= read -r supplied
      [[ "$supplied" == "$EXPECTED_TOKEN" ]]
    elif [[ "$*" == '--token-stdin' ]]; then
      IFS= read -r supplied
      [[ "$supplied" == "$EXPECTED_TOKEN" ]]
    else
      [[ "$*" == '--ci --name Adversary run action' ]]
    fi
    if [[ "${FAIL_LOGIN:-false}" == true ]]; then exit 7; fi
    ;;
  logout) [[ "$1" == --local-only ]] ;;
  run)
    if [[ "${RUN_EXIT:-0}" == 1 ]]; then
      if [[ " $* " == *" --format json "* ]]; then
        printf '%s\n' '{"protocolVersion":1,"result":{"adversary":{"name":"example"},"target":{},"positives":[],"observations":[],"findings":[{"id":"f1","title":"t","category":"c","severity":"low","confidence":"high","summary":"s","evidence":[]}],"suppressed":{"observations":0,"findings":0}}}'
      fi
      exit 1
    fi
    if [[ " $* " == *" --format json "* ]]; then
      if [[ "$*" == *"adversarylabs/a adversarylabs/b"* ]] || [[ "$*" == *"adversarylabs/a"*"adversarylabs/b"* ]]; then
        printf '%s\n' '{"results":[{"adversary":"adversarylabs/a","output":{"protocolVersion":1,"result":{"adversary":{"name":"a"},"target":{},"positives":[],"observations":[],"findings":[{"id":"1","title":"t","category":"c","severity":"low","confidence":"high","summary":"s","evidence":[]}],"suppressed":{"observations":0,"findings":0}}}},{"adversary":"adversarylabs/b","output":{"protocolVersion":1,"result":{"adversary":{"name":"b"},"target":{},"positives":[],"observations":[],"findings":[],"suppressed":{"observations":0,"findings":0}}}}]}'
      else
        printf '%s\n' '{"protocolVersion":1,"result":{"adversary":{"name":"example"},"target":{},"positives":[],"observations":[],"findings":[],"suppressed":{"observations":0,"findings":0}}}'
      fi
    else
      printf 'review ok\n'
    fi
    exit "${RUN_EXIT:-0}"
    ;;
  *) echo "unexpected command: $command" >&2; exit 9 ;;
esac
FAKE
chmod +x "$fake_bin/adversary"

mkdir -p "$tmp/work/src"
run_output="$tmp/run-output"
log="$tmp/fake.log"
: >"$log"

PATH="$fake_bin:$PATH" FAKE_LOG="$log" EXPECTED_TOKEN='adv_sa_do-not-print-me' \
  RUNNER_TEMP="$runner" GITHUB_OUTPUT="$run_output" \
  INPUT_ADVERSARIES='adversarylabs/dockerfile' INPUT_PATH=src INPUT_BASE='' INPUT_HEAD='' \
  INPUT_ALL_FILES=false INPUT_BUILDER=local INPUT_BUILD=false INPUT_FORCE=false \
  INPUT_FORMAT=text INPUT_KEEP_TEMP=false INPUT_NO_NETWORK=false INPUT_VERBOSE=false \
  INPUT_INCLUDE_SUPPRESSED=false INPUT_SHELL=false INPUT_ALLOW_UNSAFE_HOST_EXECUTION=false \
  INPUT_TIMEOUT='' INPUT_BUILD_TIMEOUT='' INPUT_MODEL_PROVIDER='' INPUT_MODEL='' \
  INPUT_MODEL_API_KEY='' INPUT_OPENAI_BASE_URL='' INPUT_ANTHROPIC_BASE_URL='' INPUT_FIREWORKS_BASE_URL='' \
  INPUT_FAIL_ON_FINDINGS=true INPUT_API_URL=https://api.example INPUT_PROFILE='' \
  INPUT_AUTH_MODE=token INPUT_TOKEN='adv_sa_do-not-print-me' INPUT_CLIENT_NAME='Adversary run action' \
  INPUT_REGISTRY_HOST='' INPUT_REGISTRY_NAMESPACE=adversarylabs \
  bash -c 'cd "$1" && bash "$2"' _ "$tmp/work" "$root/run/scripts/run.sh" >"$tmp/run-stdout"

grep -Eq 'login profile=run-action-[0-9]+-[0-9]+ args=--token-stdin --registry-namespace adversarylabs' "$log"
grep -Eq 'run profile=run-action-[0-9]+-[0-9]+ args=adversarylabs/dockerfile --path src --builder local --format text' "$log"
grep -Eq 'logout profile=run-action-[0-9]+-[0-9]+ args=--local-only' "$log"
# Ephemeral profiles must not log out a bare caller-owned name.
if grep -Eq 'logout profile=run-action args=' "$log"; then
  echo "run action logged out a non-ephemeral profile name" >&2
  exit 1
fi
grep -Fq 'exit-code=0' "$run_output"
grep -Fq 'outcome=success' "$run_output"
if grep -Fq 'adv_sa_do-not-print-me' "$log" "$tmp/run-stdout" "$run_output"; then
  echo "service account token leaked into run action output" >&2
  exit 1
fi

auto_log="$tmp/auto.log"
auto_output="$tmp/auto-output"
: >"$auto_log"
PATH="$fake_bin:$PATH" FAKE_LOG="$auto_log" RUNNER_TEMP="$runner" GITHUB_OUTPUT="$auto_output" \
  INPUT_ADVERSARIES=auto INPUT_PATH=. INPUT_BASE=main INPUT_HEAD=HEAD \
  INPUT_ALL_FILES=false INPUT_BUILDER=local INPUT_BUILD=false INPUT_FORCE=false \
  INPUT_FORMAT=text INPUT_KEEP_TEMP=false INPUT_NO_NETWORK=false INPUT_VERBOSE=false \
  INPUT_INCLUDE_SUPPRESSED=false INPUT_SHELL=false INPUT_ALLOW_UNSAFE_HOST_EXECUTION=false \
  INPUT_TIMEOUT='' INPUT_BUILD_TIMEOUT='' INPUT_MODEL_PROVIDER='' INPUT_MODEL='' \
  INPUT_MODEL_API_KEY='' INPUT_OPENAI_BASE_URL='' INPUT_ANTHROPIC_BASE_URL='' INPUT_FIREWORKS_BASE_URL='' \
  INPUT_FAIL_ON_FINDINGS=true INPUT_API_URL=https://api.example INPUT_PROFILE='' \
  INPUT_AUTH_MODE=none INPUT_TOKEN='' INPUT_CLIENT_NAME='Adversary run action' \
  INPUT_REGISTRY_HOST='' INPUT_REGISTRY_NAMESPACE='' \
  bash -c 'cd "$1" && bash "$2"' _ "$tmp/work" "$root/run/scripts/run.sh" >/dev/null

grep -Fq 'run profile=default args=--path . --format text --base main --head HEAD' "$auto_log"
grep -Fq 'exit-code=0' "$auto_output"
if grep -Fq -- '--builder' "$auto_log"; then
  echo "automatic selection passed an explicit-only builder flag" >&2
  exit 1
fi

model_log="$tmp/model.log"
model_output="$tmp/model-output"
: >"$model_log"
PATH="$fake_bin:$PATH" FAKE_LOG="$model_log" RUNNER_TEMP="$runner" GITHUB_OUTPUT="$model_output" \
  INPUT_ADVERSARIES='adversarylabs/go-cli' INPUT_PATH=. INPUT_BASE='' INPUT_HEAD='' \
  INPUT_ALL_FILES=true INPUT_BUILDER=local INPUT_BUILD=false INPUT_FORCE=false \
  INPUT_FORMAT=json INPUT_KEEP_TEMP=false INPUT_NO_NETWORK=false INPUT_VERBOSE=true \
  INPUT_INCLUDE_SUPPRESSED=true INPUT_SHELL=false INPUT_ALLOW_UNSAFE_HOST_EXECUTION=false \
  INPUT_TIMEOUT=5m INPUT_BUILD_TIMEOUT=2m INPUT_MODEL_PROVIDER=openai INPUT_MODEL=gpt-test \
  INPUT_MODEL_API_KEY='sk-do-not-print' INPUT_OPENAI_BASE_URL='https://openai.example' \
  INPUT_ANTHROPIC_BASE_URL='' INPUT_FIREWORKS_BASE_URL='' \
  INPUT_FAIL_ON_FINDINGS=true INPUT_API_URL=https://api.example INPUT_PROFILE='' \
  INPUT_AUTH_MODE=none INPUT_TOKEN='' INPUT_CLIENT_NAME='Adversary run action' \
  INPUT_REGISTRY_HOST='' INPUT_REGISTRY_NAMESPACE='' \
  bash -c 'cd "$1" && bash "$2"' _ "$tmp/work" "$root/run/scripts/run.sh" >"$tmp/model-stdout"

grep -Fq 'run profile=default args=adversarylabs/go-cli --path . --builder local --format json --all-files --verbose --include-suppressed --timeout 5m --build-timeout 2m --model-provider openai --model gpt-test' "$model_log"
grep -Fq 'env OPENAI_API_KEY=sk-do-not-print' "$model_log"
grep -Fq 'findings-count=0' "$model_output"
grep -Fq 'outcome=success' "$model_output"
grep -Fq 'result-file=' "$model_output"
model_result_file="$(sed -n 's/^result-file=//p' "$model_output" | head -n 1)"
[[ -n "$model_result_file" && -f "$model_result_file" ]]
if grep -Fq 'sk-do-not-print' "$model_output" "$tmp/model-stdout"; then
  echo "model API key leaked into action outputs" >&2
  exit 1
fi
if grep -Eq '^(login|logout) ' "$model_log"; then
  echo "none authentication unexpectedly changed CLI login state" >&2
  exit 1
fi

# Sequential JSON runs in one job must not share a result path.
second_output="$tmp/second-output"
: >"$model_log"
PATH="$fake_bin:$PATH" FAKE_LOG="$model_log" RUNNER_TEMP="$runner" GITHUB_OUTPUT="$second_output" \
  INPUT_ADVERSARIES='adversarylabs/go-cli' INPUT_PATH=. INPUT_BASE='' INPUT_HEAD='' \
  INPUT_ALL_FILES=false INPUT_BUILDER=local INPUT_BUILD=false INPUT_FORCE=false \
  INPUT_FORMAT=json INPUT_KEEP_TEMP=false INPUT_NO_NETWORK=false INPUT_VERBOSE=false \
  INPUT_INCLUDE_SUPPRESSED=false INPUT_SHELL=false INPUT_ALLOW_UNSAFE_HOST_EXECUTION=false \
  INPUT_TIMEOUT='' INPUT_BUILD_TIMEOUT='' INPUT_MODEL_PROVIDER='' INPUT_MODEL='' \
  INPUT_MODEL_API_KEY='' INPUT_OPENAI_BASE_URL='' INPUT_ANTHROPIC_BASE_URL='' INPUT_FIREWORKS_BASE_URL='' \
  INPUT_FAIL_ON_FINDINGS=true INPUT_API_URL=https://api.example INPUT_PROFILE='' \
  INPUT_AUTH_MODE=none INPUT_TOKEN='' INPUT_CLIENT_NAME='Adversary run action' \
  INPUT_REGISTRY_HOST='' INPUT_REGISTRY_NAMESPACE='' \
  bash -c 'cd "$1" && bash "$2"' _ "$tmp/work" "$root/run/scripts/run.sh" >/dev/null
second_result_file="$(sed -n 's/^result-file=//p' "$second_output" | head -n 1)"
[[ -n "$second_result_file" && -f "$second_result_file" ]]
if [[ "$model_result_file" == "$second_result_file" ]]; then
  echo "sequential JSON runs reused the same result-file path" >&2
  exit 1
fi
# First run's capture must remain intact after the second run.
grep -Fq '"protocolVersion":1' "$model_result_file"

multi_log="$tmp/multi.log"
multi_output="$tmp/multi-output"
: >"$multi_log"
PATH="$fake_bin:$PATH" FAKE_LOG="$multi_log" RUNNER_TEMP="$runner" GITHUB_OUTPUT="$multi_output" \
  INPUT_ADVERSARIES=$'adversarylabs/a\nadversarylabs/b' INPUT_PATH=. INPUT_BASE=main INPUT_HEAD=HEAD \
  INPUT_ALL_FILES=false INPUT_BUILDER=docker INPUT_BUILD=true INPUT_FORCE=true \
  INPUT_FORMAT=json INPUT_KEEP_TEMP=true INPUT_NO_NETWORK=false INPUT_VERBOSE=false \
  INPUT_INCLUDE_SUPPRESSED=false INPUT_SHELL=false INPUT_ALLOW_UNSAFE_HOST_EXECUTION=true \
  INPUT_TIMEOUT='' INPUT_BUILD_TIMEOUT='' INPUT_MODEL_PROVIDER='' INPUT_MODEL='' \
  INPUT_MODEL_API_KEY='' INPUT_OPENAI_BASE_URL='' INPUT_ANTHROPIC_BASE_URL='' INPUT_FIREWORKS_BASE_URL='' \
  INPUT_FAIL_ON_FINDINGS=true INPUT_API_URL=https://api.example INPUT_PROFILE=preconfigured \
  INPUT_AUTH_MODE=existing INPUT_TOKEN='' INPUT_CLIENT_NAME='Adversary run action' \
  INPUT_REGISTRY_HOST='' INPUT_REGISTRY_NAMESPACE='' \
  bash -c 'cd "$1" && bash "$2"' _ "$tmp/work" "$root/run/scripts/run.sh" >/dev/null

grep -Fq 'run profile=preconfigured args=adversarylabs/a adversarylabs/b --path . --builder docker --format json --base main --head HEAD --build --force --keep-temp --allow-unsafe-host-execution' "$multi_log"
grep -Fq 'findings-count=1' "$multi_output"
if grep -Eq '^(login|logout) ' "$multi_log"; then
  echo "existing authentication unexpectedly changed CLI login state" >&2
  exit 1
fi

# Explicit profile with token auth must not log out the bare caller profile name.
explicit_log="$tmp/explicit-token.log"
explicit_output="$tmp/explicit-token-output"
: >"$explicit_log"
PATH="$fake_bin:$PATH" FAKE_LOG="$explicit_log" EXPECTED_TOKEN='adv_sa_do-not-print-me' \
  RUNNER_TEMP="$runner" GITHUB_OUTPUT="$explicit_output" \
  INPUT_ADVERSARIES='adversarylabs/dockerfile' INPUT_PATH=. INPUT_BASE='' INPUT_HEAD='' \
  INPUT_ALL_FILES=false INPUT_BUILDER=local INPUT_BUILD=false INPUT_FORCE=false \
  INPUT_FORMAT=text INPUT_KEEP_TEMP=false INPUT_NO_NETWORK=false INPUT_VERBOSE=false \
  INPUT_INCLUDE_SUPPRESSED=false INPUT_SHELL=false INPUT_ALLOW_UNSAFE_HOST_EXECUTION=false \
  INPUT_TIMEOUT='' INPUT_BUILD_TIMEOUT='' INPUT_MODEL_PROVIDER='' INPUT_MODEL='' \
  INPUT_MODEL_API_KEY='' INPUT_OPENAI_BASE_URL='' INPUT_ANTHROPIC_BASE_URL='' INPUT_FIREWORKS_BASE_URL='' \
  INPUT_FAIL_ON_FINDINGS=true INPUT_API_URL=https://api.example INPUT_PROFILE=preconfigured \
  INPUT_AUTH_MODE=token INPUT_TOKEN='adv_sa_do-not-print-me' INPUT_CLIENT_NAME='Adversary run action' \
  INPUT_REGISTRY_HOST='' INPUT_REGISTRY_NAMESPACE=adversarylabs \
  bash -c 'cd "$1" && bash "$2"' _ "$tmp/work" "$root/run/scripts/run.sh" >/dev/null
grep -Eq 'login profile=preconfigured-[0-9]+-[0-9]+ args=--token-stdin --registry-namespace adversarylabs' "$explicit_log"
grep -Eq 'logout profile=preconfigured-[0-9]+-[0-9]+ args=--local-only' "$explicit_log"
if grep -Eq 'logout profile=preconfigured args=' "$explicit_log"; then
  echo "token auth logged out the caller-owned profile name" >&2
  exit 1
fi

findings_log="$tmp/findings.log"
findings_output="$tmp/findings-output"
: >"$findings_log"
if PATH="$fake_bin:$PATH" FAKE_LOG="$findings_log" RUN_EXIT=1 RUNNER_TEMP="$runner" GITHUB_OUTPUT="$findings_output" \
  INPUT_ADVERSARIES='adversarylabs/example' INPUT_PATH=. INPUT_BASE='' INPUT_HEAD='' \
  INPUT_ALL_FILES=false INPUT_BUILDER=local INPUT_BUILD=false INPUT_FORCE=false \
  INPUT_FORMAT=json INPUT_KEEP_TEMP=false INPUT_NO_NETWORK=false INPUT_VERBOSE=false \
  INPUT_INCLUDE_SUPPRESSED=false INPUT_SHELL=false INPUT_ALLOW_UNSAFE_HOST_EXECUTION=false \
  INPUT_TIMEOUT='' INPUT_BUILD_TIMEOUT='' INPUT_MODEL_PROVIDER='' INPUT_MODEL='' \
  INPUT_MODEL_API_KEY='' INPUT_OPENAI_BASE_URL='' INPUT_ANTHROPIC_BASE_URL='' INPUT_FIREWORKS_BASE_URL='' \
  INPUT_FAIL_ON_FINDINGS=true INPUT_API_URL=https://api.example INPUT_PROFILE='' \
  INPUT_AUTH_MODE=none INPUT_TOKEN='' INPUT_CLIENT_NAME='Adversary run action' \
  INPUT_REGISTRY_HOST='' INPUT_REGISTRY_NAMESPACE='' \
  bash -c 'cd "$1" && bash "$2"' _ "$tmp/work" "$root/run/scripts/run.sh" >/dev/null 2>"$tmp/findings-stderr"; then
  echo "run continued after findings with fail-on-findings true" >&2
  exit 1
fi
grep -Fq 'exit-code=1' "$findings_output"
grep -Fq 'outcome=findings' "$findings_output"
grep -Fq 'findings-count=1' "$findings_output"

soft_output="$tmp/soft-output"
: >"$findings_log"
PATH="$fake_bin:$PATH" FAKE_LOG="$findings_log" RUN_EXIT=1 RUNNER_TEMP="$runner" GITHUB_OUTPUT="$soft_output" \
  INPUT_ADVERSARIES='adversarylabs/example' INPUT_PATH=. INPUT_BASE='' INPUT_HEAD='' \
  INPUT_ALL_FILES=false INPUT_BUILDER=local INPUT_BUILD=false INPUT_FORCE=false \
  INPUT_FORMAT=json INPUT_KEEP_TEMP=false INPUT_NO_NETWORK=false INPUT_VERBOSE=false \
  INPUT_INCLUDE_SUPPRESSED=false INPUT_SHELL=false INPUT_ALLOW_UNSAFE_HOST_EXECUTION=false \
  INPUT_TIMEOUT='' INPUT_BUILD_TIMEOUT='' INPUT_MODEL_PROVIDER='' INPUT_MODEL='' \
  INPUT_MODEL_API_KEY='' INPUT_OPENAI_BASE_URL='' INPUT_ANTHROPIC_BASE_URL='' INPUT_FIREWORKS_BASE_URL='' \
  INPUT_FAIL_ON_FINDINGS=false INPUT_API_URL=https://api.example INPUT_PROFILE='' \
  INPUT_AUTH_MODE=none INPUT_TOKEN='' INPUT_CLIENT_NAME='Adversary run action' \
  INPUT_REGISTRY_HOST='' INPUT_REGISTRY_NAMESPACE='' \
  bash -c 'cd "$1" && bash "$2"' _ "$tmp/work" "$root/run/scripts/run.sh" >/dev/null
grep -Fq 'exit-code=1' "$soft_output"
grep -Fq 'outcome=findings' "$soft_output"

blank_auto_log="$tmp/blank-auto.log"
blank_auto_output="$tmp/blank-auto-output"
: >"$blank_auto_log"
PATH="$fake_bin:$PATH" FAKE_LOG="$blank_auto_log" RUNNER_TEMP="$runner" GITHUB_OUTPUT="$blank_auto_output" \
  INPUT_ADVERSARIES='' INPUT_PATH=. INPUT_AUTH_MODE=none \
  bash "$root/run/scripts/run.sh" >/dev/null
grep -Fq 'run profile=default args=--path . --format text' "$blank_auto_log"

if PATH="$fake_bin:$PATH" FAKE_LOG="$log" RUNNER_TEMP="$runner" GITHUB_OUTPUT="$run_output" \
  INPUT_ADVERSARIES='auto adversarylabs/example' INPUT_PATH=. INPUT_AUTH_MODE=none \
  bash "$root/run/scripts/run.sh" >/dev/null 2>&1; then
  echo "run accepted auto combined with an explicit adversary" >&2
  exit 1
fi

if PATH="$fake_bin:$PATH" FAKE_LOG="$log" RUNNER_TEMP="$runner" GITHUB_OUTPUT="$run_output" \
  INPUT_ADVERSARIES=auto INPUT_PATH=. INPUT_AUTH_MODE=none INPUT_FORCE=true \
  bash "$root/run/scripts/run.sh" >/dev/null 2>&1; then
  echo "automatic selection accepted an explicit-only flag" >&2
  exit 1
fi

if PATH="$fake_bin:$PATH" RUNNER_TEMP="$runner" GITHUB_OUTPUT="$run_output" \
  INPUT_ADVERSARIES='example' INPUT_PATH=. INPUT_AUTH_MODE=token INPUT_TOKEN='' \
  INPUT_ALL_FILES=false INPUT_BUILD=false INPUT_FORCE=false INPUT_FORMAT=text \
  INPUT_KEEP_TEMP=false INPUT_NO_NETWORK=false INPUT_VERBOSE=false \
  INPUT_INCLUDE_SUPPRESSED=false INPUT_SHELL=false INPUT_ALLOW_UNSAFE_HOST_EXECUTION=false \
  INPUT_FAIL_ON_FINDINGS=true INPUT_MODEL_PROVIDER='' INPUT_MODEL='' INPUT_MODEL_API_KEY='' \
  bash "$root/run/scripts/run.sh" >/dev/null 2>&1; then
  echo "run accepted token authentication without a token" >&2
  exit 1
fi

if PATH="$fake_bin:$PATH" RUNNER_TEMP="$runner" GITHUB_OUTPUT="$run_output" \
  INPUT_ADVERSARIES='example' INPUT_PATH=. INPUT_AUTH_MODE=none INPUT_TOKEN='' \
  INPUT_ALL_FILES=true INPUT_BASE=main INPUT_HEAD=HEAD INPUT_BUILD=false INPUT_FORCE=false \
  INPUT_FORMAT=text INPUT_KEEP_TEMP=false INPUT_NO_NETWORK=false INPUT_VERBOSE=false \
  INPUT_INCLUDE_SUPPRESSED=false INPUT_SHELL=false INPUT_ALLOW_UNSAFE_HOST_EXECUTION=false \
  INPUT_FAIL_ON_FINDINGS=true INPUT_MODEL_PROVIDER='' INPUT_MODEL='' INPUT_MODEL_API_KEY='' \
  INPUT_BUILDER=local \
  bash "$root/run/scripts/run.sh" >/dev/null 2>&1; then
  echo "run accepted all-files with base/head" >&2
  exit 1
fi

if PATH="$fake_bin:$PATH" RUNNER_TEMP="$runner" GITHUB_OUTPUT="$run_output" \
  INPUT_ADVERSARIES='example' INPUT_PATH=. INPUT_AUTH_MODE=none \
  INPUT_MODEL_API_KEY='sk-test' INPUT_MODEL_PROVIDER='' \
  INPUT_ALL_FILES=false INPUT_BUILD=false INPUT_FORCE=false INPUT_FORMAT=text \
  INPUT_KEEP_TEMP=false INPUT_NO_NETWORK=false INPUT_VERBOSE=false \
  INPUT_INCLUDE_SUPPRESSED=false INPUT_SHELL=false INPUT_ALLOW_UNSAFE_HOST_EXECUTION=false \
  INPUT_FAIL_ON_FINDINGS=true INPUT_BUILDER=local INPUT_TOKEN='' INPUT_MODEL='' \
  bash "$root/run/scripts/run.sh" >/dev/null 2>&1; then
  echo "run accepted model-api-key without model-provider" >&2
  exit 1
fi

echo "run action tests passed"
