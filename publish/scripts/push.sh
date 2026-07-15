#!/usr/bin/env bash
set -euo pipefail

local_reference="${INPUT_LOCAL_REFERENCE:?local package reference is required}"
profile="${INPUT_PROFILE:-github-actions}"
api_url="${INPUT_API_URL:-https://adversarylabs.ai/api}"
email="${INPUT_EMAIL_ADDRESS:-}"
password="${INPUT_PASSWORD:-}"

if [[ -n "$email" && -z "$password" || -z "$email" && -n "$password" ]]; then
  echo "email-address and password must be provided together." >&2
  exit 2
fi

export ADVERSARY_API_URL="$api_url"
if [[ -n "${INPUT_REGISTRY_HOST:-}" ]]; then export ADVERSARY_REGISTRY_HOST="$INPUT_REGISTRY_HOST"; fi
if [[ -n "${INPUT_REGISTRY_NAMESPACE:-}" ]]; then export ADVERSARY_REGISTRY_NAMESPACE="$INPUT_REGISTRY_NAMESPACE"; fi

if [[ -n "$password" ]]; then
  printf '%s\n' "$password" | env -u INPUT_PASSWORD adversary --profile "$profile" login --ci --email-address "$email" --password-stdin
  password=''
  unset INPUT_PASSWORD
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
