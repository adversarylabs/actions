#!/usr/bin/env bash
set -euo pipefail

require_bool() {
  local name="$1" value="$2"
  case "$value" in
    true|false) ;;
    *) echo "${name} must be true or false" >&2; exit 2 ;;
  esac
}

adversaries_raw="${INPUT_ADVERSARIES:-}"
path="${INPUT_PATH:-.}"
base="${INPUT_BASE:-}"
head="${INPUT_HEAD:-}"
all_files="${INPUT_ALL_FILES:-false}"
builder="${INPUT_BUILDER:-local}"
build="${INPUT_BUILD:-false}"
force="${INPUT_FORCE:-false}"
format="${INPUT_FORMAT:-text}"
keep_temp="${INPUT_KEEP_TEMP:-false}"
no_network="${INPUT_NO_NETWORK:-false}"
verbose="${INPUT_VERBOSE:-false}"
include_suppressed="${INPUT_INCLUDE_SUPPRESSED:-false}"
shell_mode="${INPUT_SHELL:-false}"
allow_unsafe_host_execution="${INPUT_ALLOW_UNSAFE_HOST_EXECUTION:-false}"
timeout="${INPUT_TIMEOUT:-}"
build_timeout="${INPUT_BUILD_TIMEOUT:-}"
model_provider="${INPUT_MODEL_PROVIDER:-}"
model="${INPUT_MODEL:-}"
model_api_key="${INPUT_MODEL_API_KEY:-}"
openai_base_url="${INPUT_OPENAI_BASE_URL:-}"
anthropic_base_url="${INPUT_ANTHROPIC_BASE_URL:-}"
fireworks_base_url="${INPUT_FIREWORKS_BASE_URL:-}"
fail_on_findings="${INPUT_FAIL_ON_FINDINGS:-true}"
api_url="${INPUT_API_URL:-https://adversarylabs.ai/api}"
profile="${INPUT_PROFILE:-}"
auth_mode="${INPUT_AUTH_MODE:-none}"
token="${INPUT_TOKEN:-}"
client_name="${INPUT_CLIENT_NAME:-Adversary run action}"
unset INPUT_TOKEN INPUT_MODEL_API_KEY

if [[ -z "${adversaries_raw//[[:space:]]/}" ]]; then
  echo "adversaries is required" >&2
  exit 2
fi

# shellcheck disable=SC2206
adversaries=()
while IFS= read -r line; do
  # shellcheck disable=SC2086
  for ref in $line; do
    [[ -n "$ref" ]] || continue
    adversaries+=("$ref")
  done
done <<<"$adversaries_raw"

if [[ ${#adversaries[@]} -eq 0 ]]; then
  echo "adversaries is required" >&2
  exit 2
fi

require_bool all-files "$all_files"
require_bool build "$build"
require_bool force "$force"
require_bool keep-temp "$keep_temp"
require_bool no-network "$no_network"
require_bool verbose "$verbose"
require_bool include-suppressed "$include_suppressed"
require_bool shell "$shell_mode"
require_bool allow-unsafe-host-execution "$allow_unsafe_host_execution"
require_bool fail-on-findings "$fail_on_findings"

case "$format" in
  text|json) ;;
  *) echo "format must be text or json" >&2; exit 2 ;;
esac
case "$builder" in
  local|docker) ;;
  *) echo "builder must be local or docker" >&2; exit 2 ;;
esac
case "$auth_mode" in
  none|token|oauth|existing) ;;
  *) echo "auth-mode must be none, token, oauth, or existing" >&2; exit 2 ;;
esac
if [[ "$auth_mode" != token && -n "$token" ]]; then
  echo "token can only be used with auth-mode: token" >&2
  exit 2
fi
if [[ "$all_files" == true && ( -n "$base" || -n "$head" ) ]]; then
  echo "all-files cannot be combined with base or head" >&2
  exit 2
fi
if [[ "$shell_mode" == true && "$no_network" == true ]]; then
  echo "shell cannot be combined with no-network" >&2
  exit 2
fi
if [[ "$shell_mode" == true && "$format" == json ]]; then
  echo "shell cannot be combined with format: json" >&2
  exit 2
fi
if [[ "$shell_mode" == true && ${#adversaries[@]} -gt 1 ]]; then
  echo "shell cannot be combined with multiple adversaries" >&2
  exit 2
fi
if [[ ! -d "$path" ]]; then
  echo "Source path does not exist: ${path}" >&2
  exit 2
fi

model_provider="$(printf '%s' "$model_provider" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
model="$(printf '%s' "$model" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
case "$model_provider" in
  ""|openai|anthropic|fireworks) ;;
  *) echo "model-provider must be openai, anthropic, or fireworks" >&2; exit 2 ;;
esac
if [[ -n "$model_api_key" && -z "$model_provider" ]]; then
  echo "model-provider is required when model-api-key is set" >&2
  exit 2
fi
if [[ -n "$model_api_key" ]]; then
  case "$model_provider" in
    openai) export OPENAI_API_KEY="$model_api_key" ;;
    anthropic) export ANTHROPIC_API_KEY="$model_api_key" ;;
    fireworks) export FIREWORKS_API_KEY="$model_api_key" ;;
  esac
  model_api_key=''
fi
if [[ -n "$openai_base_url" ]]; then export ADVERSARY_OPENAI_BASE_URL="$openai_base_url"; fi
if [[ -n "$anthropic_base_url" ]]; then export ADVERSARY_ANTHROPIC_BASE_URL="$anthropic_base_url"; fi
if [[ -n "$fireworks_base_url" ]]; then export ADVERSARY_FIREWORKS_BASE_URL="$fireworks_base_url"; fi

# Token/OAuth always use an ephemeral action-owned profile so cleanup cannot
# remove a caller-owned profile that happens to share a name.
owns_temp_profile=false
if [[ "$auth_mode" == token || "$auth_mode" == oauth ]]; then
  profile_prefix="${profile:-run-action}"
  profile="${profile_prefix}-${BASHPID:-$$}-${RANDOM}"
  owns_temp_profile=true
fi

export ADVERSARY_API_URL="$api_url"
if [[ -n "${INPUT_REGISTRY_HOST:-}" ]]; then export ADVERSARY_REGISTRY_HOST="$INPUT_REGISTRY_HOST"; fi
if [[ -n "${INPUT_REGISTRY_NAMESPACE:-}" ]]; then export ADVERSARY_REGISTRY_NAMESPACE="$INPUT_REGISTRY_NAMESPACE"; fi

cleanup_auth() {
  if [[ "${owns_temp_profile:-false}" == true && -n "${profile:-}" ]]; then
    adversary --profile "$profile" logout --local-only >/dev/null 2>&1 || true
  fi
}
trap cleanup_auth EXIT

if [[ "$auth_mode" == token ]]; then
  if [[ -z "$token" ]]; then
    echo "token is required with auth-mode: token" >&2
    exit 2
  fi
  if [[ "$token" != adv_sa_* ]]; then
    echo "token must be an Adversary Labs service account token" >&2
    exit 2
  fi
  login_args=(--profile "$profile" login --token-stdin)
  if [[ -n "${INPUT_REGISTRY_NAMESPACE:-}" ]]; then
    login_args+=(--registry-namespace "$INPUT_REGISTRY_NAMESPACE")
  fi
  printf '%s\n' "$token" | adversary "${login_args[@]}"
  token=''
elif [[ "$auth_mode" == oauth ]]; then
  adversary --profile "$profile" login --ci --name "$client_name"
fi

run_args=(run)
run_args+=("${adversaries[@]}")
run_args+=(--path "$path")
run_args+=(--builder "$builder")
run_args+=(--format "$format")
if [[ -n "$base" ]]; then run_args+=(--base "$base"); fi
if [[ -n "$head" ]]; then run_args+=(--head "$head"); fi
if [[ "$all_files" == true ]]; then run_args+=(--all-files); fi
if [[ "$build" == true ]]; then run_args+=(--build); fi
if [[ "$force" == true ]]; then run_args+=(--force); fi
if [[ "$keep_temp" == true ]]; then run_args+=(--keep-temp); fi
if [[ "$no_network" == true ]]; then run_args+=(--no-network); fi
if [[ "$verbose" == true ]]; then run_args+=(--verbose); fi
if [[ "$include_suppressed" == true ]]; then run_args+=(--include-suppressed); fi
if [[ "$shell_mode" == true ]]; then run_args+=(--shell); fi
if [[ "$allow_unsafe_host_execution" == true ]]; then run_args+=(--allow-unsafe-host-execution); fi
if [[ -n "$timeout" ]]; then run_args+=(--timeout "$timeout"); fi
if [[ -n "$build_timeout" ]]; then run_args+=(--build-timeout "$build_timeout"); fi
if [[ -n "$model_provider" ]]; then run_args+=(--model-provider "$model_provider"); fi
if [[ -n "$model" ]]; then run_args+=(--model "$model"); fi

result_file=""
findings_count=""
run_stdout=""
if [[ "$format" == json ]]; then
  # Unique per invocation so concurrent or sequential run steps in one job
  # do not overwrite each other's result-file outputs.
  result_file="$(mktemp "${RUNNER_TEMP:?RUNNER_TEMP is required}/adversary-run.XXXXXX")"
  run_stdout="$result_file"
fi

set +e
if [[ -n "$profile" && "$auth_mode" != none ]]; then
  if [[ -n "$run_stdout" ]]; then
    adversary --profile "$profile" "${run_args[@]}" >"$run_stdout"
  else
    adversary --profile "$profile" "${run_args[@]}"
  fi
else
  if [[ -n "$run_stdout" ]]; then
    adversary "${run_args[@]}" >"$run_stdout"
  else
    adversary "${run_args[@]}"
  fi
fi
exit_code=$?
set -e

if [[ "$format" == json && -f "$result_file" ]]; then
  cat "$result_file"
  findings_count="$(python3 - "$result_file" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    payload = json.load(stream)

def count_findings(value):
    if not isinstance(value, dict):
        return 0
    # Single-run review envelope
    if "protocolVersion" in value and isinstance(value.get("result"), dict):
        findings = value["result"].get("findings")
        return len(findings) if isinstance(findings, list) else 0
    # Multi-run CLI envelope: {results:[{output|error}, ...]} or writeJSON shape
    if isinstance(value.get("results"), list):
        total = 0
        for item in value["results"]:
            if not isinstance(item, dict):
                continue
            output = item.get("output")
            if isinstance(output, (dict, list)):
                total += count_findings(output) if isinstance(output, dict) else 0
            elif isinstance(output, str) and output.strip():
                try:
                    total += count_findings(json.loads(output))
                except json.JSONDecodeError:
                    pass
        return total
    data = value.get("data")
    if isinstance(data, dict) and isinstance(data.get("results"), list):
        return count_findings({"results": data["results"]})
    return 0

print(count_findings(payload))
PY
  )" || findings_count=""
fi

outcome=failure
case "$exit_code" in
  0) outcome=success ;;
  1) outcome=findings ;;
  *) outcome=failure ;;
esac

{
  printf 'exit-code=%s\n' "$exit_code"
  printf 'findings-count=%s\n' "$findings_count"
  printf 'result-file=%s\n' "$result_file"
  printf 'outcome=%s\n' "$outcome"
} >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

if [[ "$exit_code" -eq 1 && "$fail_on_findings" == false ]]; then
  printf 'adversary run reported findings (exit 1); fail-on-findings is false\n' >&2
  exit 0
fi

exit "$exit_code"
