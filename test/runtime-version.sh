#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

write_node_fixture() {
  local project="$1"
  mkdir -p "$project/src" "$project/dist"
  cat >"$project/adversary.yaml" <<'EOF'
name: test/runtime
version: 0.0.1
runtime:
  name: node
  version: "22"
  command:
    - dist/index.js
EOF
  cat >"$project/package.json" <<'EOF'
{
  "name": "runtime-fixture",
  "version": "0.0.2",
  "type": "module",
  "private": true,
  "scripts": { "build": "node build.mjs" }
}
EOF
  cat >"$project/package-lock.json" <<'EOF'
{
  "name": "runtime-fixture",
  "version": "0.0.2",
  "lockfileVersion": 3,
  "requires": true,
  "packages": { "": { "name": "runtime-fixture", "version": "0.0.2" } }
}
EOF
  cat >"$project/build.mjs" <<'EOF'
import { copyFile, mkdir } from "node:fs/promises"
await mkdir("dist", { recursive: true })
await copyFile("src/index.ts", "dist/index.js")
EOF
  git -C "$project" init >/dev/null
  git -C "$project" config user.name test
  git -C "$project" config user.email test@example.com
}

hardcoded="$tmp/hardcoded"
mkdir -p "$hardcoded"
write_node_fixture "$hardcoded"
cat >"$hardcoded/src/index.ts" <<'EOF'
class Adversary { constructor(options) { Object.assign(this, options) } }
export function createApp() {
  // version: "comment-must-not-change"
  return new Adversary({ name: "test/runtime", version: "0.0.1" })
}
EOF
cp "$hardcoded/src/index.ts" "$hardcoded/dist/index.js"
git -C "$hardcoded" add .
git -C "$hardcoded" commit -m initial >/dev/null
(
  cd "$hardcoded"
  node "$root/version/scripts/runtime.mjs" apply . 0.0.2 runtime-output.json
)
grep -Fq 'version: "0.0.2"' "$hardcoded/src/index.ts"
grep -Fq 'comment-must-not-change' "$hardcoded/src/index.ts"
grep -Fq 'version: "0.0.2"' "$hardcoded/dist/index.js"
node "$root/version/scripts/runtime.mjs" verify "$hardcoded" 0.0.2
node -e '
  const files = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).files
  if (!files.some(file => file.endsWith("src/index.ts")) || !files.some(file => file.endsWith("dist/index.js"))) process.exit(1)
' "$hardcoded/runtime-output.json"

inferred="$tmp/inferred"
mkdir -p "$inferred"
write_node_fixture "$inferred"
cat >"$inferred/src/index.ts" <<'EOF'
import packageDocument from "../package.json" with { type: "json" }
class Adversary { constructor(options) { Object.assign(this, options) } }
export const constructorExample = /new Adversary({ version: "0.0.1" })/
export function createApp() {
  return new Adversary({ name: "test/runtime", version: packageDocument.version })
}
EOF
git -C "$inferred" add .
git -C "$inferred" commit -m initial >/dev/null
(
  cd "$inferred"
  node "$root/version/scripts/runtime.mjs" apply . 0.0.2 runtime-output.json
)
grep -Fq 'version: packageDocument.version' "$inferred/src/index.ts"
grep -Fq '/new Adversary({ version: "0.0.1" })/' "$inferred/src/index.ts"
grep -Fq '/new Adversary({ version: "0.0.1" })/' "$inferred/dist/index.js"
node "$root/version/scripts/runtime.mjs" verify "$inferred" 0.0.2

regex_statement="$tmp/regex-statement"
mkdir -p "$regex_statement"
write_node_fixture "$regex_statement"
cat >"$regex_statement/src/index.ts" <<'EOF'
import packageDocument from "../package.json" with { type: "json" }
class Adversary { constructor(options) { Object.assign(this, options) } }
if (false) /new Adversary({ version: "0.0.1" })/.test("")
export function createApp() {
  return Reflect.construct(Adversary, [{ name: "test/runtime", version: packageDocument.version }])
}
EOF
git -C "$regex_statement" add .
git -C "$regex_statement" commit -m initial >/dev/null
(
  cd "$regex_statement"
  node "$root/version/scripts/runtime.mjs" apply . 0.0.2 runtime-output.json
)
grep -Fq 'if (false) /new Adversary({ version: "0.0.1" })/.test("")' "$regex_statement/src/index.ts"
grep -Fq 'if (false) /new Adversary({ version: "0.0.1" })/.test("")' "$regex_statement/dist/index.js"
node "$root/version/scripts/runtime.mjs" verify "$regex_statement" 0.0.2

ambiguous_division="$tmp/ambiguous-division"
mkdir -p "$ambiguous_division"
write_node_fixture "$ambiguous_division"
cat >"$ambiguous_division/src/index.ts" <<'EOF'
import packageDocument from "../package.json" with { type: "json" }
class Adversary { constructor(options) { Object.assign(this, options) } }
const value = 2 / new Adversary({ version: "0.0.1", weight: 2 }).weight / 1
export function createApp() {
  return Reflect.construct(Adversary, [{ name: "test/runtime", version: packageDocument.version, value }])
}
EOF
cp "$ambiguous_division/src/index.ts" "$ambiguous_division/dist/index.js"
if (cd "$ambiguous_division" && node "$root/version/scripts/runtime.mjs" apply . 0.0.2 runtime-output.json) 2>"$tmp/ambiguous-division-error"; then
  echo "runtime synchronization accepted ambiguous division syntax" >&2
  exit 1
fi
grep -Fq 'ambiguous slash syntax' "$tmp/ambiguous-division-error"
grep -Fq 'new Adversary({ version: "0.0.1"' "$ambiguous_division/src/index.ts"

omitted="$tmp/omitted"
mkdir -p "$omitted"
write_node_fixture "$omitted"
cat >"$omitted/src/index.ts" <<'EOF'
class Adversary { constructor(options) { Object.assign(this, options) } }
export function createApp() { return new Adversary({ name: "test/runtime" }) }
EOF
if (cd "$omitted" && node "$root/version/scripts/runtime.mjs" apply . 0.0.2 runtime-output.json) 2>"$tmp/omitted-error"; then
  echo "runtime verification accepted an omitted runtime version" >&2
  exit 1
fi
grep -Fq 'expected 0.0.2' "$tmp/omitted-error"

non_node="$tmp/non-node"
mkdir -p "$non_node"
cat >"$non_node/adversary.yaml" <<'EOF'
name: test/static
version: 0.0.2
runtime:
  name: docker
  image: example.invalid/test/static:0.0.2
EOF
(
  cd "$non_node"
  node "$root/version/scripts/runtime.mjs" apply . 0.0.2 runtime-output.json
)
grep -Fq '"files":[]' "$non_node/runtime-output.json"

echo "runtime version tests passed"
