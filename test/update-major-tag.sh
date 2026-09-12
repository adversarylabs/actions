#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"

case "$*" in
  *'/git/matching-refs/tags/'*' --jq '* ) printf '%s\n' "$MATCHING_REFS" ;;
  *'/commits/'*' --jq .sha') printf '%s\n' "$RELEASE_SHA" ;;
  *'-X GET repos/'*'/git/ref/tags/'*)
    if [[ "${REF_EXISTS:-true}" != true ]]; then exit 1; fi
    ;;
  *'-X PATCH '*|*'-X POST '*) ;;
  *) echo "unexpected gh invocation: $*" >&2; exit 2 ;;
esac
FAKE
chmod +x "$tmp/bin/gh"

sha=4eb7c1f8027bd9f84db513ccca475b3f591104d4
log="$tmp/gh.log"
PATH="$tmp/bin:$PATH" GH_LOG="$log" MATCHING_REFS=$'refs/tags/v1.4.6\nrefs/tags/v1.4.7\nrefs/tags/v1.5.0-beta.1' RELEASE_SHA="$sha" \
  GITHUB_REPOSITORY=adversarylabs/actions RELEASE_TAG=v1.4.7 \
  bash "$root/scripts/update-major-tag.sh"
grep -Fq -- "-X PATCH repos/adversarylabs/actions/git/refs/tags/v1 -f sha=$sha -F force=true" "$log"

: >"$log"
PATH="$tmp/bin:$PATH" GH_LOG="$log" MATCHING_REFS=$'refs/tags/v2.0.0' RELEASE_SHA="$sha" REF_EXISTS=false \
  GITHUB_REPOSITORY=adversarylabs/actions RELEASE_TAG=v2.0.0 \
  bash "$root/scripts/update-major-tag.sh"
grep -Fq -- "-X POST repos/adversarylabs/actions/git/refs -f ref=refs/tags/v2 -f sha=$sha" "$log"

: >"$log"
PATH="$tmp/bin:$PATH" GH_LOG="$log" MATCHING_REFS=$'refs/tags/v1.4.6\nrefs/tags/v1.4.7' RELEASE_SHA="$sha" \
  GITHUB_REPOSITORY=adversarylabs/actions RELEASE_TAG=v1.4.6 \
  bash "$root/scripts/update-major-tag.sh"
if grep -Eq -- '-X (PATCH|POST)' "$log"; then
  echo "an older release moved the major tag" >&2
  exit 1
fi

if PATH="$tmp/bin:$PATH" GH_LOG="$log" MATCHING_REFS=$'refs/tags/v1.4.7' RELEASE_SHA="$sha" \
  GITHUB_REPOSITORY=adversarylabs/actions RELEASE_TAG=v1.4 \
  bash "$root/scripts/update-major-tag.sh" >/dev/null 2>&1; then
  echo "an invalid stable release tag was accepted" >&2
  exit 1
fi

echo "major tag update tests passed"
