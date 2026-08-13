#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bash -n "$root/version/scripts/version.sh"
grep -Fq 'using: composite' "$root/version/action.yml"
grep -Fq 'sync-npm:' "$root/version/action.yml"
grep -Fq 'changed:' "$root/version/action.yml"

remote="$tmp/remote.git"
seed="$tmp/seed"
git init --bare "$remote" >/dev/null
git init "$seed" >/dev/null
git -C "$seed" switch -c main >/dev/null
git -C "$seed" config user.name test
git -C "$seed" config user.email test@example.com

cat >"$seed/adversary.yaml" <<'EOF'
name: depotci
version: 0.0.1
description: Test adversary.
runtime:
  name: node
  version: "22"
  command:
    - dist/index.js
EOF
cat >"$seed/package.json" <<'EOF'
{
    "name" : "depotci",

    "version" : "0.1.0",
    "private" : true,
    "type" : "module",
    "scripts" : { "build": "node build.mjs" }
}
EOF
cat >"$seed/package-lock.json" <<'EOF'
{
  "name": "depotci",
  "version": "0.1.0",
  "lockfileVersion": 3,
  "packages": {
    "": {
      "name": "depotci",
      "version": "0.1.0"
    }
  }
}
EOF
mkdir -p "$seed/src" "$seed/dist"
cat >"$seed/src/index.ts" <<'EOF'
import { execFileSync } from "node:child_process"
class Adversary { constructor(options) { Object.assign(this, options) } }
export function createApp() {
  try {
    const credential = execFileSync("git", ["config", "--local", "--get-all", "http.https://github.com/.extraheader"], { encoding: "utf8" })
    if (credential.trim()) throw new Error("repository code could read Git credentials")
  } catch (error) {
    if (error?.message === "repository code could read Git credentials") throw error
  }
  return new Adversary({ name: "depotci", version: "0.0.1" })
}
EOF
cat >"$seed/build.mjs" <<'EOF'
import { copyFile, mkdir } from "node:fs/promises"
await mkdir("dist", { recursive: true })
await copyFile("src/index.ts", "dist/index.js")
EOF
cp "$seed/src/index.ts" "$seed/dist/index.js"

git -C "$seed" add adversary.yaml package.json package-lock.json src/index.ts dist/index.js build.mjs
git -C "$seed" commit -m initial >/dev/null
initial_sha="$(git -C "$seed" rev-parse HEAD)"
git -C "$seed" remote add origin "$remote"
git -C "$seed" push -u origin main >/dev/null
git --git-dir="$remote" symbolic-ref HEAD refs/heads/main
# Simulate actions/checkout's default persisted credential. Repository build
# code must never run while this or the release credential is readable.
git -C "$seed" config --local http.https://github.com/.extraheader 'AUTHORIZATION: basic checkout-do-not-expose'

runner="$tmp/runner"
mkdir -p "$runner"
first_output="$tmp/first-output"
first_log="$tmp/first-log"
INPUT_TAG=v0.0.2 INPUT_PATH=. INPUT_BRANCH=main INPUT_TOKEN=github-do-not-print-me \
  INPUT_SYNC_NPM=auto GITHUB_WORKSPACE="$seed" GITHUB_ACTION_PATH="$root/version" \
  GITHUB_SHA="$initial_sha" RUNNER_TEMP="$runner" GITHUB_OUTPUT="$first_output" \
  bash "$root/version/scripts/version.sh" >"$first_log" 2>&1

grep -Fq 'name=depotci' "$first_output"
grep -Fq 'version=0.0.2' "$first_output"
grep -Fq 'changed=true' "$first_output"
bump_sha="$(sed -n 's/^commit=//p' "$first_output")"
[[ -n "$bump_sha" ]]
[[ "$(git --git-dir="$remote" rev-parse main)" == "$bump_sha" ]]
[[ "$(git --git-dir="$remote" log -1 --format=%s main)" == 'chore: bump adversary version to 0.0.2 [skip-ci]' ]]
[[ "$(git --git-dir="$remote" show main:adversary.yaml | sed -n 's/^version:[[:space:]]*//p')" == 0.0.2 ]]
[[ "$(git --git-dir="$remote" show main:package.json | node -e 'let data=""; process.stdin.on("data", chunk => data += chunk); process.stdin.on("end", () => console.log(JSON.parse(data).version))')" == 0.0.2 ]]
[[ "$(git --git-dir="$remote" show main:package-lock.json | node -e 'let data=""; process.stdin.on("data", chunk => data += chunk); process.stdin.on("end", () => console.log(JSON.parse(data).packages[""].version))')" == 0.0.2 ]]
git --git-dir="$remote" show main:src/index.ts | grep -Fq 'version: "0.0.2"'
git --git-dir="$remote" show main:dist/index.js | grep -Fq 'version: "0.0.2"'
git --git-dir="$remote" show main:package.json | grep -Fq '    "name" : "depotci",'
git --git-dir="$remote" show main:package.json | grep -Fq '    "version" : "0.0.2",'
[[ "$(git -C "$seed" config --local user.name)" == test ]]
[[ "$(git -C "$seed" config --local user.email)" == test@example.com ]]
if grep -Fq 'github-do-not-print-me' "$first_log" "$first_output"; then
  echo "version action leaked its GitHub token" >&2
  exit 1
fi
encoded_token="$(printf 'x-access-token:%s' 'github-do-not-print-me' | base64 | tr -d '\n')"
if grep -Fq "$encoded_token" "$first_log" "$first_output"; then
  echo "version action leaked its Git authentication header" >&2
  exit 1
fi
if git -C "$seed" config --local --get-all http.https://github.com/.extraheader >/dev/null; then
  echo "version action retained Git credentials" >&2
  exit 1
fi

rerun="$tmp/rerun"
git clone "$remote" "$rerun" >/dev/null
git -C "$rerun" switch --detach "$initial_sha" >/dev/null
rerun_output="$tmp/rerun-output"
INPUT_TAG=v0.0.2 INPUT_PATH=. INPUT_BRANCH=main INPUT_TOKEN=github-do-not-print-me \
  INPUT_SYNC_NPM=auto GITHUB_WORKSPACE="$rerun" GITHUB_ACTION_PATH="$root/version" \
  GITHUB_SHA="$initial_sha" RUNNER_TEMP="$runner" GITHUB_OUTPUT="$rerun_output" \
  bash "$root/version/scripts/version.sh" >/dev/null

grep -Fq 'name=depotci' "$rerun_output"
grep -Fq 'version=0.0.2' "$rerun_output"
grep -Fq 'changed=false' "$rerun_output"
grep -Fq "commit=$bump_sha" "$rerun_output"
[[ "$(git --git-dir="$remote" rev-parse main)" == "$bump_sha" ]]
[[ "$(sed -n 's/^version:[[:space:]]*//p' "$rerun/adversary.yaml")" == 0.0.2 ]]

if INPUT_TAG=latest INPUT_PATH=. INPUT_BRANCH=main INPUT_TOKEN=github-do-not-print-me \
  INPUT_SYNC_NPM=auto GITHUB_WORKSPACE="$rerun" GITHUB_ACTION_PATH="$root/version" \
  GITHUB_SHA="$initial_sha" RUNNER_TEMP="$runner" GITHUB_OUTPUT="$rerun_output" \
  bash "$root/version/scripts/version.sh" >/dev/null 2>&1; then
  echo "version action accepted a non-version tag" >&2
  exit 1
fi

echo "version action tests passed"
