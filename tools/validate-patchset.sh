#!/usr/bin/env bash
# validate-patchset.sh -- compile gate. Checks out a clean NVIDIA
# open-gpu-kernel-modules tree at the target tag, applies the composed
# patch set, and runs `make modules`.
#
# Usage: validate-patchset.sh [--fork DIR] [--tag TAG|--nvidia-tag TAG] [--kernel KVER]
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/nvidia-version.sh
. "$repo_root/tools/lib/nvidia-version.sh"

fork="${FORK_REPO:-/root/open-gpu-kernel-modules}"
tag=""
kver="$(uname -r)"
while [ $# -gt 0 ]; do
    case "$1" in
        --fork)   fork="$2"; shift 2 ;;
        --tag|--nvidia-tag) tag="$2"; shift 2 ;;
        --kernel) kver="$2"; shift 2 ;;
        *) echo "validate: unknown arg '$1'" >&2; exit 2 ;;
    esac
done
if [ -z "$tag" ]; then
    if nvidia_version_load "$repo_root" 2>/dev/null; then
        tag="$NVIDIA_OPEN_TAG"
    else
        tag="$(nvidia_dockerfile_tag "$repo_root/Dockerfile" 2>/dev/null || true)"
    fi
fi
[ -n "$tag" ] || { echo "validate: could not determine target tag" >&2; exit 1; }
nvidia_version_validate_tag "$tag" || exit 1

ksrc="/lib/modules/$kver/build"
[ -d "$ksrc" ]      || { echo "validate: kernel build dir $ksrc not found" >&2; exit 1; }
[ -d "$fork/.git" ] || { echo "validate: fork repo not found at $fork" >&2; exit 1; }

work="$(mktemp -d)"
src="$work/src"
cleanup() {
    git -C "$fork" worktree remove --force "$src" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

echo "validate: checking out vanilla $tag ..."
git -C "$fork" worktree add --detach "$src" "refs/tags/$tag" >/dev/null 2>&1 \
    || { echo "validate: could not check out tag $tag from $fork" >&2; exit 1; }

echo "validate: composing patch set ..."
apply_list="$("$repo_root/tools/compose-patchset.sh" --patches-dir "$repo_root/patches")"

echo "validate: applying patches ..."
while read -r p; do
    [ -n "$p" ] || continue
    echo "  apply ${p##*/}"
    git -C "$src" apply --check "$p"
    git -C "$src" apply "$p"
done <<EOF
$apply_list
EOF

echo "validate: make modules (kernel $kver) ..."
if make -C "$src" modules SYSSRC="$ksrc" -j"$(nproc)" IGNORE_CC_MISMATCH=1 \
        > "$work/build.log" 2>&1; then
    echo "validate: OK -- composed patch set compiles against kernel $kver"
else
    echo "validate: BUILD FAILED -- tail of build log:" >&2
    tail -40 "$work/build.log" >&2
    exit 1
fi
