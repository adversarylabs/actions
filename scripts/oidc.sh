#!/usr/bin/env bash
set -euo pipefail

api_url="${INPUT_API_URL:-https://adversarylabs.ai/api}"
team="${INPUT_REGISTRY_NAMESPACE:-}"
operation="${OIDC_OPERATION:?OIDC_OPERATION is required}"
output="${OIDC_OUTPUT:?OIDC_OUTPUT is required}"

if [[ -z "$team" ]]; then
  echo "registry-namespace is required with auth-mode: oidc" >&2
  exit 2
fi
if [[ "$operation" != pull && "$operation" != push ]]; then
  echo "OIDC operation must be pull or push" >&2
  exit 2
fi
if [[ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" || -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; then
  echo "OIDC is unavailable. Add permissions: id-token: write to the job." >&2
  exit 2
fi

separator='?'
if [[ "$ACTIONS_ID_TOKEN_REQUEST_URL" == *\?* ]]; then separator='&'; fi
oidc_response="$(mktemp "${RUNNER_TEMP:?RUNNER_TEMP is required}/adversary-oidc.XXXXXX")"
exchange_response="$(mktemp "${RUNNER_TEMP}/adversary-exchange.XXXXXX")"
trap 'rm -f "$oidc_response" "$exchange_response"' EXIT
chmod 600 "$oidc_response" "$exchange_response"

curl --fail --silent --show-error \
  -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}${separator}audience=https%3A%2F%2Fadversarylabs.ai" \
  >"$oidc_response"

oidc_token="$(python3 - "$oidc_response" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    value = json.load(stream).get("value")
if not isinstance(value, str) or value.count(".") != 2:
    raise SystemExit("CI provider returned an invalid OIDC token")
print(value)
PY
)"

request_body="$(python3 - "$team" "$operation" <<'PY'
import json, sys
print(json.dumps({"team": sys.argv[1], "operation": sys.argv[2]}))
PY
)"
status="$(curl --silent --show-error \
  -o "$exchange_response" -w '%{http_code}' \
  -H "Authorization: Bearer ${oidc_token}" \
  -H 'Content-Type: application/json' \
  --data "$request_body" \
  "${api_url%/}/v1/auth/ci/exchange")"
oidc_token=''
if [[ "$status" != 200 ]]; then
  message="$(python3 - "$exchange_response" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        value = json.load(stream).get("error")
    print(value if isinstance(value, str) else "CI identity exchange was denied")
except Exception:
    print("CI identity exchange was denied")
PY
)"
  echo "$message (HTTP $status)" >&2
  exit 4
fi

python3 - "$exchange_response" "$output" <<'PY'
import json, os, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    payload = json.load(stream)
token = payload.get("token")
namespace = payload.get("namespace")
if not isinstance(token, str) or not token.startswith("adv_ci_"):
    raise SystemExit("Adversary Labs returned an invalid CI access token")
if not isinstance(namespace, str) or not namespace:
    raise SystemExit("Adversary Labs returned an invalid registry namespace")
fd = os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as stream:
    stream.write(token + "\n" + namespace + "\n")
PY
