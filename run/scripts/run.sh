#!/usr/bin/env bash
set -euo pipefail

require_bool() {
  local name="$1" value="$2"
  case "$value" in
    true|false) ;;
    *) echo "${name} must be true or false" >&2; exit 2 ;;
  esac
}

adversaries_raw="${INPUT_ADVERSARIES:-auto}"
path="${INPUT_PATH:-.}"
data_dir="${INPUT_DATA_DIR:-${ADVERSARY_DATA_DIR:-}}"
base="${INPUT_BASE:-}"
head="${INPUT_HEAD:-}"
all_files="${INPUT_ALL_FILES:-false}"
github_review="${INPUT_GITHUB_REVIEW:-auto}"
github_submit="${INPUT_GITHUB_SUBMIT:-true}"
include_summary="${INPUT_INCLUDE_SUMMARY:-true}"
resolve_addressed_comments="${INPUT_RESOLVE_ADDRESSED_COMMENTS:-true}"
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
cloudflare_account_id="${INPUT_CLOUDFLARE_ACCOUNT_ID:-${CLOUDFLARE_ACCOUNT_ID:-}}"
cloudflare_gateway_id="${INPUT_CLOUDFLARE_GATEWAY_ID:-}"
cloudflare_base_url="${INPUT_CLOUDFLARE_BASE_URL:-}"
anthropic_base_url="${INPUT_ANTHROPIC_BASE_URL:-}"
fireworks_base_url="${INPUT_FIREWORKS_BASE_URL:-}"
camel_base_url="${INPUT_CAMEL_BASE_URL:-}"
fail_on_findings="${INPUT_FAIL_ON_FINDINGS:-false}"
api_url="${INPUT_API_URL:-https://adversarylabs.ai/api}"
profile="${INPUT_PROFILE:-}"
auth_mode="${INPUT_AUTH_MODE:-none}"
token="${INPUT_TOKEN:-}"
client_name="${INPUT_CLIENT_NAME:-Adversary run action}"
unset INPUT_TOKEN INPUT_MODEL_API_KEY

if [[ -z "$data_dir" ]]; then
  data_dir="${RUNNER_TEMP:?RUNNER_TEMP is required}/adversary-data"
fi
case "$data_dir" in
  /*) ;;
  *) echo "data-dir must be an absolute path" >&2; exit 2 ;;
esac
mkdir -p -- "$data_dir"
export ADVERSARY_DATA_DIR="$data_dir"

adversaries=()
auto_select=false
adversaries_value="$(printf '%s' "$adversaries_raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
if [[ -z "$adversaries_value" || "$adversaries_value" == auto ]]; then
  auto_select=true
else
  while IFS= read -r line; do
    # shellcheck disable=SC2086
    for ref in $line; do
      [[ -n "$ref" ]] || continue
      if [[ "$ref" == auto ]]; then
        echo "auto cannot be combined with explicit adversary references" >&2
        exit 2
      fi
      adversaries+=("$ref")
    done
  done <<<"$adversaries_value"

  if [[ ${#adversaries[@]} -eq 0 ]]; then
    auto_select=true
  fi
fi

require_bool all-files "$all_files"
require_bool github-submit "$github_submit"
require_bool include-summary "$include_summary"
require_bool resolve-addressed-comments "$resolve_addressed_comments"
require_bool build "$build"
require_bool force "$force"
require_bool keep-temp "$keep_temp"
require_bool no-network "$no_network"
require_bool verbose "$verbose"
require_bool include-suppressed "$include_suppressed"
require_bool shell "$shell_mode"
require_bool allow-unsafe-host-execution "$allow_unsafe_host_execution"
require_bool fail-on-findings "$fail_on_findings"

case "$github_review" in
  auto)
    github_review_enabled=false
    if [[ "${GITHUB_EVENT_NAME:-}" == pull_request || "${GITHUB_EVENT_NAME:-}" == pull_request_target || "${GITHUB_REF:-}" == refs/pull/* ]]; then
      github_review_enabled=true
    fi
    ;;
  true|false) github_review_enabled="$github_review" ;;
  *) echo "github-review must be auto, true, or false" >&2; exit 2 ;;
esac

case "$format" in
  text|json) ;;
  *) echo "format must be text or json" >&2; exit 2 ;;
esac
case "$builder" in
  local|docker) ;;
  *) echo "builder must be local or docker" >&2; exit 2 ;;
esac
case "$auth_mode" in
  none|oidc|token|oauth|existing) ;;
  *) echo "auth-mode must be none, oidc, token, oauth, or existing" >&2; exit 2 ;;
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
if [[ "$auto_select" == true ]]; then
  if [[ "$builder" != local ]]; then
    echo "builder cannot be used with automatic selection" >&2
    exit 2
  fi
  if [[ "$build" == true || "$force" == true || "$keep_temp" == true || "$no_network" == true || "$verbose" == true || "$shell_mode" == true || -n "$build_timeout" ]]; then
    echo "build, force, keep-temp, no-network, verbose, shell, and build-timeout apply only to explicit adversary references" >&2
    exit 2
  fi
fi
if [[ ! -d "$path" ]]; then
  echo "Source path does not exist: ${path}" >&2
  exit 2
fi

model_provider="$(printf '%s' "$model_provider" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
model="$(printf '%s' "$model" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
cloudflare_account_id="$(printf '%s' "$cloudflare_account_id" | tr -d '[:space:]')"
case "$model_provider" in
  ""|openai|cloudflare|anthropic|fireworks|camel|camel-stream) ;;
  *) echo "model-provider must be openai, cloudflare, anthropic, fireworks, or camel" >&2; exit 2 ;;
esac
effective_model_provider="${model_provider:-${ADVERSARY_MODEL_PROVIDER:-}}"
effective_model_provider="$(printf '%s' "$effective_model_provider" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
effective_model="${model:-${ADVERSARY_MODEL:-}}"
effective_model="$(printf '%s' "$effective_model" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
case "$effective_model_provider" in
  ""|openai|cloudflare|anthropic|fireworks|camel|camel-stream) ;;
  *) echo "ADVERSARY_MODEL_PROVIDER must be openai, cloudflare, anthropic, fireworks, or camel" >&2; exit 2 ;;
esac
if [[ "$effective_model_provider" == cloudflare && -z "$cloudflare_account_id" ]]; then
  echo "cloudflare-account-id is required when model-provider is cloudflare" >&2
  exit 2
fi
if [[ -z "$effective_model" ]]; then
  echo "model is required for CI reviews (set model or ADVERSARY_MODEL)" >&2
  exit 2
fi
if [[ -n "$model_api_key" && -z "$effective_model_provider" ]]; then
  echo "model-provider is required when model-api-key is set" >&2
  exit 2
fi
if [[ -n "$model_api_key" ]]; then
  case "$effective_model_provider" in
    openai) export OPENAI_API_KEY="$model_api_key" ;;
    cloudflare) export CLOUDFLARE_API_TOKEN="$model_api_key" ;;
    anthropic) export ANTHROPIC_API_KEY="$model_api_key" ;;
    fireworks) export FIREWORKS_API_KEY="$model_api_key" ;;
    camel|camel-stream) export CAMEL_API_KEY="$model_api_key" ;;
  esac
  model_api_key=''
fi

# CI reviews must never silently degrade to the non-model reviewers. Validate
# the same provider credential contract the CLI uses before any review jobs run.
if [[ -z "$effective_model_provider" ]]; then
  configured_model_providers=()
  [[ -n "${OPENAI_API_KEY:-}" ]] && configured_model_providers+=(openai)
  if [[ -n "${CLOUDFLARE_API_TOKEN:-}" || -n "$cloudflare_account_id" ]]; then
    if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
      echo "CLOUDFLARE_API_TOKEN is required for model provider cloudflare" >&2
      exit 2
    fi
    if [[ -z "$cloudflare_account_id" ]]; then
      echo "cloudflare-account-id or CLOUDFLARE_ACCOUNT_ID is required for model provider cloudflare" >&2
      exit 2
    fi
    configured_model_providers+=(cloudflare)
  fi
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] && configured_model_providers+=(anthropic)
  [[ -n "${FIREWORKS_API_KEY:-}" ]] && configured_model_providers+=(fireworks)
  [[ -n "${CAMEL_API_KEY:-}" ]] && configured_model_providers+=(camel)
  if [[ ${#configured_model_providers[@]} -eq 0 ]]; then
    echo "a model provider API key is required for CI reviews" >&2
    exit 2
  fi
  if [[ ${#configured_model_providers[@]} -gt 1 ]]; then
    echo "model-provider or ADVERSARY_MODEL_PROVIDER is required when multiple model provider keys are configured" >&2
    exit 2
  fi
  effective_model_provider="${configured_model_providers[0]}"
fi
case "$effective_model_provider" in
  openai) model_key="${OPENAI_API_KEY:-}" ;;
  cloudflare) model_key="${CLOUDFLARE_API_TOKEN:-}" ;;
  anthropic) model_key="${ANTHROPIC_API_KEY:-}" ;;
  fireworks) model_key="${FIREWORKS_API_KEY:-}" ;;
  camel|camel-stream) model_key="${CAMEL_API_KEY:-}" ;;
esac
if [[ -z "$model_key" ]]; then
  echo "the API key for model provider ${effective_model_provider} is required for CI reviews" >&2
  exit 2
fi
if [[ -n "$openai_base_url" ]]; then export ADVERSARY_OPENAI_BASE_URL="$openai_base_url"; fi
if [[ -n "$cloudflare_account_id" ]]; then export CLOUDFLARE_ACCOUNT_ID="$cloudflare_account_id"; fi
if [[ -n "$cloudflare_gateway_id" ]]; then export ADVERSARY_CLOUDFLARE_GATEWAY_ID="$cloudflare_gateway_id"; fi
if [[ -n "$cloudflare_base_url" ]]; then export ADVERSARY_CLOUDFLARE_BASE_URL="$cloudflare_base_url"; fi
if [[ -n "$anthropic_base_url" ]]; then export ADVERSARY_ANTHROPIC_BASE_URL="$anthropic_base_url"; fi
if [[ -n "$fireworks_base_url" ]]; then export ADVERSARY_FIREWORKS_BASE_URL="$fireworks_base_url"; fi
if [[ -n "$camel_base_url" ]]; then export ADVERSARY_CAMEL_BASE_URL="$camel_base_url"; fi

# Token/OAuth always use an ephemeral action-owned profile so cleanup cannot
# remove a caller-owned profile that happens to share a name.
owns_temp_profile=false
if [[ "$auth_mode" == oidc || "$auth_mode" == token || "$auth_mode" == oauth ]]; then
  profile_prefix="${profile:-run-action}"
  profile="${profile_prefix}-${BASHPID:-$$}-${RANDOM}"
  owns_temp_profile=true
fi

export ADVERSARY_API_URL="$api_url"
if [[ -n "${INPUT_REGISTRY_HOST:-}" ]]; then export ADVERSARY_REGISTRY_HOST="$INPUT_REGISTRY_HOST"; fi
if [[ -n "${INPUT_REGISTRY_NAMESPACE:-}" ]]; then export ADVERSARY_REGISTRY_NAMESPACE="$INPUT_REGISTRY_NAMESPACE"; fi

cleanup_auth() {
  if [[ -n "${credential_file:-}" ]]; then rm -f "$credential_file"; fi
  if [[ -n "${captured_stdout:-}" ]]; then rm -f "$captured_stdout"; fi
  if [[ "${owns_temp_profile:-false}" == true && -n "${profile:-}" ]]; then
    adversary --profile "$profile" logout --local-only >/dev/null 2>&1 || true
  fi
}
credential_file=""
captured_stdout=""
trap cleanup_auth EXIT
review_pid=""
cancel_review() {
  local exit_code="$1"
  # Finish shutdown before authentication cleanup, even if cancellation repeats.
  trap '' TERM INT
  if [[ -n "$review_pid" ]]; then
    kill -TERM "$review_pid" 2>/dev/null || true
    wait "$review_pid" 2>/dev/null || true
  fi
  exit "$exit_code"
}
trap 'cancel_review 143' TERM
trap 'cancel_review 130' INT

if [[ "$auth_mode" == oidc ]]; then
  credential_file="$(mktemp "${RUNNER_TEMP:?RUNNER_TEMP is required}/adversary-ci-token.XXXXXX")"
  chmod 600 "$credential_file"
  OIDC_OPERATION=pull OIDC_OUTPUT="$credential_file" \
    bash "$GITHUB_ACTION_PATH/../scripts/oidc.sh"
  token="$(sed -n '1p' "$credential_file")"
  namespace="$(sed -n '2p' "$credential_file")"
  rm -f "$credential_file"
  credential_file=""
  [[ "$token" == adv_ci_* && "$namespace" == "${INPUT_REGISTRY_NAMESPACE:-}" ]] || {
    echo "OIDC exchange returned unexpected credentials" >&2; exit 4;
  }
  printf '%s\n' "$token" | adversary --profile "$profile" login --token-stdin --registry-namespace "$namespace"
  token=''
elif [[ "$auth_mode" == token ]]; then
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
if [[ "$auto_select" == false ]]; then run_args+=("${adversaries[@]}"); fi
run_args+=(--path "$path")
if [[ "$auto_select" == false ]]; then run_args+=(--builder "$builder"); fi
run_args+=(--format "$format")
if [[ -n "$base" ]]; then run_args+=(--base "$base"); fi
if [[ -n "$head" ]]; then run_args+=(--head "$head"); fi
if [[ "$all_files" == true ]]; then run_args+=(--all-files); fi
if [[ "$auto_select" == false && "$build" == true ]]; then run_args+=(--build); fi
if [[ "$auto_select" == false && "$force" == true ]]; then run_args+=(--force); fi
if [[ "$auto_select" == false && "$keep_temp" == true ]]; then run_args+=(--keep-temp); fi
if [[ "$auto_select" == false && "$no_network" == true ]]; then run_args+=(--no-network); fi
if [[ "$auto_select" == false && "$verbose" == true ]]; then run_args+=(--verbose); fi
if [[ "$include_suppressed" == true ]]; then run_args+=(--include-suppressed); fi
if [[ "$auto_select" == false && "$shell_mode" == true ]]; then run_args+=(--shell); fi
if [[ "$allow_unsafe_host_execution" == true ]]; then run_args+=(--allow-unsafe-host-execution); fi
if [[ -n "$timeout" ]]; then run_args+=(--timeout "$timeout"); fi
if [[ "$auto_select" == false && -n "$build_timeout" ]]; then run_args+=(--build-timeout "$build_timeout"); fi
if [[ -n "$model_provider" ]]; then run_args+=(--model-provider "$model_provider"); fi
if [[ -n "$model" ]]; then run_args+=(--model "$model"); fi
if [[ "$github_review_enabled" == true ]]; then
  run_args+=(--github-review)
  if [[ "$github_submit" == true ]]; then run_args+=(--github-submit); fi
  if [[ "$include_summary" == false ]]; then run_args+=(--github-include-summary=false); fi
  if [[ "$resolve_addressed_comments" == false ]]; then run_args+=(--github-resolve-addressed=false); fi
fi

result_file=""
findings_count=""
run_stdout=""
if [[ "$format" == json ]]; then
  # Unique per invocation so concurrent or sequential run steps in one job
  # do not overwrite each other's result-file outputs.
  result_file="$(mktemp "${RUNNER_TEMP:?RUNNER_TEMP is required}/adversary-run.XXXXXX")"
  run_stdout="$result_file"
else
  captured_stdout="$(mktemp "${RUNNER_TEMP:?RUNNER_TEMP is required}/adversary-run-stdout.XXXXXX")"
  run_stdout="$captured_stdout"
fi

review_command=(python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/timeout.py" adversary)

if [[ -n "$profile" && "$auth_mode" != none ]]; then
  review_command+=(--profile "$profile")
fi
review_command+=("${run_args[@]}")

set +e
# An asynchronous child plus wait lets Bash handle cancellation immediately;
# a foreground command would defer the trap until the review finishes.
"${review_command[@]}" >"$run_stdout" &
review_pid=$!
wait "$review_pid"
exit_code=$?
review_pid=""
set -e

if [[ -s "$run_stdout" ]]; then
  cat "$run_stdout"
fi

incomplete_review=false
if [[ "$format" == json ]]; then
  if python3 - "$run_stdout" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        payload = json.load(stream)
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)

def has_incomplete_review(value):
    if isinstance(value, dict):
        if value.get("key") == "composition.incomplete":
            return True
        return any(has_incomplete_review(item) for item in value.values())
    if isinstance(value, list):
        return any(has_incomplete_review(item) for item in value)
    return False

raise SystemExit(0 if has_incomplete_review(payload) else 1)
PY
  then
    incomplete_review=true
  fi
elif grep -Eq 'Partial review: [0-9]+ review jobs failed;' "$run_stdout"; then
  incomplete_review=true
fi

if [[ "$format" == json && -s "$result_file" ]]; then
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

if [[ "$incomplete_review" == true && ( "$exit_code" -eq 0 || "$exit_code" -eq 1 ) ]]; then
  echo "adversary run produced an incomplete review; failing CI because partial reviews are not accepted" >&2
  exit_code=3
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
