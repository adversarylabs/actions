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
  *'-X PATCH '*|*'-X POST '*) [[ "${FAIL_UPDATE:-false}" != true ]] ;;
  'release view '*)
    [[ "${RELEASE_EXISTS:-false}" == true ]] || exit 1
    printf '%s\n' "${RELEASE_DRAFT:-false}"
    ;;
  'release create '*|'release edit '*) ;;
  *) echo "unexpected gh invocation: $*" >&2; exit 2 ;;
esac
FAKE
chmod +x "$tmp/bin/gh"

sha=4eb7c1f8027bd9f84db513ccca475b3f591104d4
log="$tmp/gh.log"
PATH="$tmp/bin:$PATH" GH_LOG="$log" MATCHING_REFS=$'refs/tags/v1.4.6\nrefs/tags/v1.4.7\nrefs/tags/v1.5.0-beta.1' RELEASE_SHA="$sha" \
  GITHUB_REPOSITORY=doomerlabs/actions RELEASE_TAG=v1.4.7 \
  bash "$root/scripts/update-major-tag.sh"
grep -Fq -- "-X PATCH repos/doomerlabs/actions/git/refs/tags/v1 -f sha=$sha -F force=true" "$log"

: >"$log"
PATH="$tmp/bin:$PATH" GH_LOG="$log" MATCHING_REFS=$'refs/tags/v2.0.0' RELEASE_SHA="$sha" REF_EXISTS=false \
  GITHUB_REPOSITORY=doomerlabs/actions RELEASE_TAG=v2.0.0 \
  bash "$root/scripts/update-major-tag.sh"
grep -Fq -- "-X POST repos/doomerlabs/actions/git/refs -f ref=refs/tags/v2 -f sha=$sha" "$log"

: >"$log"
PATH="$tmp/bin:$PATH" GH_LOG="$log" MATCHING_REFS=$'refs/tags/v1.4.6\nrefs/tags/v1.4.7' RELEASE_SHA="$sha" \
  GITHUB_REPOSITORY=doomerlabs/actions RELEASE_TAG=v1.4.6 \
  bash "$root/scripts/update-major-tag.sh"
if grep -Eq -- '-X (PATCH|POST)' "$log"; then
  echo "an older release moved the major tag" >&2
  exit 1
fi

if PATH="$tmp/bin:$PATH" GH_LOG="$log" MATCHING_REFS=$'refs/tags/v1.4.7' RELEASE_SHA="$sha" \
  GITHUB_REPOSITORY=doomerlabs/actions RELEASE_TAG=v1.4 \
  bash "$root/scripts/update-major-tag.sh" >/dev/null 2>&1; then
  echo "an invalid stable release tag was accepted" >&2
  exit 1
fi

echo "major tag update tests passed"

: >"$log"
PATH="$tmp/bin:$PATH" GH_LOG="$log" MATCHING_REFS=refs/tags/v1.4.7 RELEASE_SHA="$sha" \
  GITHUB_REPOSITORY=doomerlabs/actions RELEASE_TAG=v1.4.7 \
  bash "$root/scripts/release.sh"
grep -Fq -- "-X PATCH repos/doomerlabs/actions/git/refs/tags/v1 -f sha=$sha -F force=true" "$log"
grep -Fq 'release create v1.4.7 --repo doomerlabs/actions --verify-tag' "$log"

: >"$log"
if PATH="$tmp/bin:$PATH" GH_LOG="$log" MATCHING_REFS=refs/tags/v1.4.7 RELEASE_SHA="$sha" FAIL_UPDATE=true \
  GITHUB_REPOSITORY=doomerlabs/actions RELEASE_TAG=v1.4.7 \
  bash "$root/scripts/release.sh"; then
  echo "release ignored a failed major-tag update" >&2
  exit 1
fi
if grep -Eq 'release (create|edit)' "$log"; then
  echo "release was published without updating the major tag" >&2
  exit 1
fi

for draft in false true; do
  : >"$log"
  PATH="$tmp/bin:$PATH" GH_LOG="$log" MATCHING_REFS=refs/tags/v1.4.7 RELEASE_SHA="$sha" \
    RELEASE_EXISTS=true RELEASE_DRAFT="$draft" GITHUB_REPOSITORY=doomerlabs/actions RELEASE_TAG=v1.4.7 \
    bash "$root/scripts/release.sh"
  if grep -Fq 'release create' "$log"; then
    echo "release rerun tried to recreate an existing release" >&2
    exit 1
  fi
  if [[ "$draft" == true ]]; then
    grep -Fq 'release edit v1.4.7 --repo doomerlabs/actions --draft=false' "$log"
  fi
done

echo "release publication tests passed"
