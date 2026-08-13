#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bash -n "$root/scripts/oidc.sh"

mkdir -p "$tmp/bin" "$tmp/runner"
fake_log="$tmp/curl.log"
cat >"$tmp/bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_LOG"
output=''
is_exchange=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    --data) is_exchange=true; shift 2 ;;
    *) shift ;;
  esac
done
if [[ "$is_exchange" == true ]]; then
  printf '{"token":"adv_ci_short-lived","namespace":"acme"}\n' >"$output"
  printf '200'
else
  printf '{"value":"header.payload.signature"}\n'
fi
FAKE
chmod +x "$tmp/bin/curl"

credential="$tmp/credential"
PATH="$tmp/bin:$PATH" FAKE_LOG="$fake_log" RUNNER_TEMP="$tmp/runner" \
  ACTIONS_ID_TOKEN_REQUEST_URL='https://identity.example/token?job=1' \
  ACTIONS_ID_TOKEN_REQUEST_TOKEN='request-secret' \
  INPUT_API_URL='https://adversarylabs.ai/api' INPUT_REGISTRY_NAMESPACE=acme \
  OIDC_OPERATION=push OIDC_OUTPUT="$credential" bash "$root/scripts/oidc.sh"

[[ "$(sed -n '1p' "$credential")" == adv_ci_short-lived ]]
[[ "$(sed -n '2p' "$credential")" == acme ]]
grep -Fq 'audience=https%3A%2F%2Fadversarylabs.ai' "$fake_log"
grep -Fq 'https://adversarylabs.ai/api/v1/auth/ci/exchange' "$fake_log"

if PATH="$tmp/bin:$PATH" RUNNER_TEMP="$tmp/runner" \
  INPUT_REGISTRY_NAMESPACE=acme OIDC_OPERATION=pull OIDC_OUTPUT="$credential" \
  bash "$root/scripts/oidc.sh" >/dev/null 2>&1; then
  echo "OIDC helper accepted a job without id-token permission" >&2
  exit 1
fi

echo "oidc tests passed"
