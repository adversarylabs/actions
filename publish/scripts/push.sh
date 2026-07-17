#!/usr/bin/env bash
set -euo pipefail

local_reference="${INPUT_LOCAL_REFERENCE:?local package reference is required}"
profile="${INPUT_PROFILE:-publish-action}"
api_url="${INPUT_API_URL:-https://adversarylabs.ai/api}"
auth_mode="${INPUT_AUTH_MODE:-token}"
client_name="${INPUT_CLIENT_NAME:-Adversary publish action}"
token="${INPUT_TOKEN:-}"

case "$auth_mode" in
  token|oauth|existing) ;;
  *) echo "auth-mode must be token, oauth, or existing" >&2; exit 2 ;;
esac
if [[ "$auth_mode" != token && -n "$token" ]]; then
  echo "token can only be used with auth-mode: token" >&2
  exit 2
fi

export ADVERSARY_API_URL="$api_url"
if [[ -n "${INPUT_REGISTRY_HOST:-}" ]]; then export ADVERSARY_REGISTRY_HOST="$INPUT_REGISTRY_HOST"; fi
if [[ -n "${INPUT_REGISTRY_NAMESPACE:-}" ]]; then export ADVERSARY_REGISTRY_NAMESPACE="$INPUT_REGISTRY_NAMESPACE"; fi

if [[ "$auth_mode" == token ]]; then
  if [[ -z "$token" ]]; then
    echo "token is required with auth-mode: token" >&2
    exit 2
  fi
  if [[ "$token" != adv_sa_* ]]; then
    echo "token must be an Adversary Labs service account token" >&2
    exit 2
  fi
  if [[ -z "${INPUT_REGISTRY_NAMESPACE:-}" && -z "${INPUT_REMOTE_REFERENCE:-}" ]]; then
    echo "registry-namespace or remote-reference is required with auth-mode: token" >&2
    exit 2
  fi
  login_args=(--profile "$profile" login --token-stdin)
  if [[ -n "${INPUT_REGISTRY_NAMESPACE:-}" ]]; then login_args+=(--registry-namespace "$INPUT_REGISTRY_NAMESPACE"); fi
  printf '%s\n' "$token" | env -u INPUT_TOKEN adversary "${login_args[@]}"
  token=''
  unset INPUT_TOKEN
  trap 'adversary --profile "$profile" logout --local-only >/dev/null 2>&1 || true' EXIT
elif [[ "$auth_mode" == oauth ]]; then
  adversary --profile "$profile" login --ci --name "$client_name"
  trap 'adversary --profile "$profile" logout --local-only >/dev/null 2>&1 || true' EXIT
fi

push_output="${RUNNER_TEMP:?RUNNER_TEMP is required}/adversary-push.json"
push_args=(push "$local_reference" --format json)
if [[ -n "${INPUT_REMOTE_REFERENCE:-}" ]]; then push_args=(push "$local_reference" "$INPUT_REMOTE_REFERENCE" --format json); fi
adversary --profile "$profile" "${push_args[@]}" >"$push_output"

publication_values="${RUNNER_TEMP}/adversary-publication-values"
python3 - "$push_output" >"$publication_values" <<'PY'
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
reference="$(sed -n '1p' "$publication_values")"
digest="$(sed -n '2p' "$publication_values")"
manifest_digest="$(sed -n '3p' "$publication_values")"
if [[ -z "$reference" || -z "$digest" || -z "$manifest_digest" || "$(wc -l <"$publication_values" | tr -d ' ')" != 3 ]]; then
  echo "adversary push returned incomplete publication metadata" >&2
  exit 3
fi

{
  printf 'reference=%s\n' "$reference"
  printf 'digest=%s\n' "$digest"
  printf 'manifest-digest=%s\n' "$manifest_digest"
} >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

printf 'Published %s\n' "$reference"
printf 'Digest: %s\n' "$digest"
