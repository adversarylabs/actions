#!/usr/bin/env bash
set -euo pipefail

local_reference="${INPUT_LOCAL_REFERENCE:?local package reference is required}"
profile="${INPUT_PROFILE:-}"
api_url="${INPUT_API_URL:-https://adversarylabs.ai/api}"
auth_mode="${INPUT_AUTH_MODE:-auto}"
client_name="${INPUT_CLIENT_NAME:-Adversary push action}"
token="${INPUT_TOKEN:-}"
remote_reference="${INPUT_REMOTE_REFERENCE:-}"
repository_name="${INPUT_REPOSITORY_NAME:-}"
push_latest="${INPUT_PUSH_LATEST:-false}"
unset INPUT_TOKEN

# v1 originally defaulted to token auth. Auto keeps callers that supplied the
# token input working while making secretless OIDC the default for new jobs.
if [[ "$auth_mode" == auto ]]; then
  if [[ -n "$token" ]]; then auth_mode=token; else auth_mode=oidc; fi
fi

case "$auth_mode" in
  oidc|token|oauth|existing) ;;
  *) echo "auth-mode must be auto, oidc, token, oauth, or existing" >&2; exit 2 ;;
esac
if [[ "$auth_mode" != token && -n "$token" ]]; then
  echo "token can only be used with auth-mode: token" >&2
  exit 2
fi
case "$push_latest" in
  true|false) ;;
  *) echo "push-latest must be true or false" >&2; exit 2 ;;
esac
if [[ -n "$remote_reference" && -n "$repository_name" ]]; then
  echo "remote-reference and repository-name cannot be used together" >&2
  exit 2
fi
if [[ -n "$repository_name" ]]; then
  if [[ -z "${INPUT_REGISTRY_NAMESPACE:-}" ]]; then
    echo "registry-namespace is required with repository-name" >&2
    exit 2
  fi
  # Single-segment repo name, or domain/name catalog path (e.g. go/security).
  if [[ ! "$repository_name" =~ ^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)?$ ]]; then
    echo "repository-name must be a lowercase OCI repository path without a registry host or tag" >&2
    exit 2
  fi
  registry_host="${INPUT_REGISTRY_HOST:-registry.adversarylabs.ai}"
  if [[ -z "$registry_host" || "$registry_host" == *://* || "$registry_host" == */* ]]; then
    echo "registry-host must be a registry hostname without a URL scheme or path" >&2
    exit 2
  fi
  local_tag="$(python3 - "$local_reference" <<'PY'
import re
import sys

last_component = sys.argv[1].rsplit("/", 1)[-1]
if ":" not in last_component:
    raise SystemExit("the packaged canonical reference does not contain a tag")
tag = last_component.rsplit(":", 1)[1]
if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}", tag):
    raise SystemExit("the packaged canonical reference contains an invalid tag")
print(tag)
PY
  )"
  # When repository-name already includes a domain path (go/security), do not
  # nest it under registry-namespace (which would produce adversarylabs/go/security).
  if [[ "$repository_name" == */* ]]; then
    remote_reference="${registry_host}/${repository_name}:${local_tag}"
  else
    remote_reference="${registry_host}/${INPUT_REGISTRY_NAMESPACE}/${repository_name}:${local_tag}"
  fi
fi
if [[ -z "$profile" && "$auth_mode" != existing ]]; then
  profile=push-action
fi
if [[ "$auth_mode" == oidc || "$auth_mode" == token || "$auth_mode" == oauth ]]; then
  profile="${profile}-${BASHPID:-$$}-${RANDOM}"
fi

owns_temp_profile=false
if [[ "$auth_mode" == oidc || "$auth_mode" == token || "$auth_mode" == oauth ]]; then
  owns_temp_profile=true
fi
credential_file=""
cleanup_auth() {
  if [[ -n "${credential_file:-}" ]]; then rm -f "$credential_file"; fi
  if [[ "${owns_temp_profile:-false}" == true && -n "${profile:-}" ]]; then
    adversary --profile "$profile" logout --local-only >/dev/null 2>&1 || true
  fi
}
trap cleanup_auth EXIT

export ADVERSARY_API_URL="$api_url"
if [[ -n "${INPUT_REGISTRY_HOST:-}" ]]; then export ADVERSARY_REGISTRY_HOST="$INPUT_REGISTRY_HOST"; fi
if [[ -n "${INPUT_REGISTRY_NAMESPACE:-}" ]]; then export ADVERSARY_REGISTRY_NAMESPACE="$INPUT_REGISTRY_NAMESPACE"; fi

if [[ "$auth_mode" == oidc ]]; then
  credential_file="$(mktemp "${RUNNER_TEMP:?RUNNER_TEMP is required}/adversary-ci-token.XXXXXX")"
  chmod 600 "$credential_file"
  OIDC_OPERATION=push OIDC_OUTPUT="$credential_file" \
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
  if [[ -z "${INPUT_REGISTRY_NAMESPACE:-}" && -z "$remote_reference" ]]; then
    echo "registry-namespace or remote-reference is required with auth-mode: token" >&2
    exit 2
  fi
  login_args=(--profile "$profile" login --token-stdin)
  if [[ -n "${INPUT_REGISTRY_NAMESPACE:-}" ]]; then login_args+=(--registry-namespace "$INPUT_REGISTRY_NAMESPACE"); fi
  printf '%s\n' "$token" | adversary "${login_args[@]}"
  token=''
elif [[ "$auth_mode" == oauth ]]; then
  adversary --profile "$profile" login --ci --name "$client_name"
fi

push_output="${RUNNER_TEMP:?RUNNER_TEMP is required}/adversary-push.json"
push_args=(push "$local_reference" --format json)
if [[ -n "$remote_reference" ]]; then push_args=(push "$local_reference" "$remote_reference" --format json); fi
if [[ -n "$profile" ]]; then
  adversary --profile "$profile" "${push_args[@]}" >"$push_output"
else
  adversary "${push_args[@]}" >"$push_output"
fi

push_values="${RUNNER_TEMP}/adversary-push-values"
python3 - "$push_output" >"$push_values" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    envelope = json.load(stream)
if envelope.get("command") != "push" or not isinstance(envelope.get("data"), dict):
    raise SystemExit("adversary push returned an unexpected JSON envelope")
data = envelope["data"]
for key in ("canonicalReference", "digest", "manifestDigest"):
    value = data.get(key)
    if not isinstance(value, str) or not value:
        raise SystemExit(f"adversary push did not return {key}")
    print(value)
PY
reference="$(sed -n '1p' "$push_values")"
digest="$(sed -n '2p' "$push_values")"
manifest_digest="$(sed -n '3p' "$push_values")"
if [[ -z "$reference" || -z "$digest" || -z "$manifest_digest" || "$(wc -l <"$push_values" | tr -d ' ')" != 3 ]]; then
  echo "adversary push returned incomplete metadata" >&2
  exit 3
fi

latest_reference=""
if [[ "$push_latest" == true ]]; then
  latest_reference="$(python3 - "$reference" <<'PY'
import sys

reference = sys.argv[1]
if "@" in reference:
    repository = reference.split("@", 1)[0]
else:
    repository, separator, _ = reference.rpartition(":")
    if not separator or "/" not in repository:
        raise SystemExit("pushed reference does not contain an explicit registry and tag")
print(f"{repository}:latest")
PY
  )"
  latest_output="${RUNNER_TEMP}/adversary-push-latest.json"
  latest_args=(push "$local_reference" "$latest_reference" --format json)
  if [[ -n "$profile" ]]; then
    adversary --profile "$profile" "${latest_args[@]}" >"$latest_output"
  else
    adversary "${latest_args[@]}" >"$latest_output"
  fi
  python3 - "$latest_output" "$latest_reference" "$digest" "$manifest_digest" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    envelope = json.load(stream)
data = envelope.get("data")
if envelope.get("command") != "push" or not isinstance(data, dict):
    raise SystemExit("adversary latest push returned an unexpected JSON envelope")
if data.get("canonicalReference") != sys.argv[2]:
    raise SystemExit("adversary latest push returned an unexpected canonical reference")
if data.get("digest") != sys.argv[3] or data.get("manifestDigest") != sys.argv[4]:
    raise SystemExit("adversary latest push returned different digests")
PY
fi

{
  printf 'reference=%s\n' "$reference"
  printf 'digest=%s\n' "$digest"
  printf 'manifest-digest=%s\n' "$manifest_digest"
  printf 'latest-reference=%s\n' "$latest_reference"
} >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

printf 'Pushed %s\n' "$reference"
printf 'Digest: %s\n' "$digest"
if [[ -n "$latest_reference" ]]; then printf 'Also pushed %s\n' "$latest_reference"; fi
