#!/usr/bin/env bash
set -euo pipefail

project_path="${INPUT_PATH:-.}"
builder="${INPUT_BUILDER:-local}"
install_dependencies="${INPUT_INSTALL_DEPENDENCIES:-true}"

case "$builder" in
  local|docker) ;;
  *) echo "builder must be local or docker" >&2; exit 2 ;;
esac
case "$install_dependencies" in
  true|false) ;;
  *) echo "install-dependencies must be true or false" >&2; exit 2 ;;
esac
if [[ ! -d "$project_path" ]]; then
  echo "Adversary project path does not exist: ${project_path}" >&2
  exit 2
fi

adversary validate "$project_path"

if [[ "$install_dependencies" == true && "$builder" == local ]]; then
  if [[ -f "$project_path/package-lock.json" ]]; then
    (cd "$project_path" && npm ci)
  elif [[ -f "$project_path/pnpm-lock.yaml" ]]; then
    if ! command -v corepack >/dev/null 2>&1; then
      echo "Installing pnpm dependencies requires Corepack. Install Corepack before running this action, or set install-dependencies: false." >&2
      exit 2
    fi
    (cd "$project_path" && corepack pnpm install --frozen-lockfile)
  elif [[ -f "$project_path/yarn.lock" ]]; then
    if ! command -v corepack >/dev/null 2>&1; then
      echo "Installing Yarn dependencies requires Corepack. Install Corepack before running this action, or set install-dependencies: false." >&2
      exit 2
    fi
    (cd "$project_path" && corepack yarn install --frozen-lockfile)
  else
    echo "Local packaging requires a supported lockfile (package-lock.json, pnpm-lock.yaml, or yarn.lock), or install-dependencies: false." >&2
    exit 2
  fi
fi

pack_output="${RUNNER_TEMP:?RUNNER_TEMP is required}/adversary-pack.json"
pack_args=(pack "$project_path" --builder "$builder" --format json)
if [[ -n "${INPUT_NAME:-}" ]]; then pack_args+=(--name "$INPUT_NAME"); fi
adversary "${pack_args[@]}" >"$pack_output"

local_reference="$(python3 - "$pack_output" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    envelope = json.load(stream)
if envelope.get("command") != "pack" or not isinstance(envelope.get("data"), dict):
    raise SystemExit("adversary pack returned an unexpected JSON envelope")
value = envelope["data"].get("canonicalReference")
if not isinstance(value, str) or not value:
    raise SystemExit("adversary pack did not return a canonical reference")
print(value)
PY
)"
printf 'local-reference=%s\n' "$local_reference" >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
