#!/usr/bin/env bash
# export-r610-modules.sh — copy patched .ko into the unsigned staging dir.
#
# Build-only. Never signs, never loads, never touches extra/nvidia/
# (stock 610.57.04 rollback path).
#
#   ./scripts/export-r610-modules.sh --from /path/to/kernel-open
#   ./scripts/export-r610-modules.sh --from ... --dest /path/to/unsigned
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../tools/lib/platform.sh
. "$REPO_ROOT/tools/lib/platform.sh"
# shellcheck source=../tools/lib/nvidia-version.sh
. "$REPO_ROOT/tools/lib/nvidia-version.sh"
# shellcheck source=../tools/lib/module-sign.sh
. "$REPO_ROOT/tools/lib/module-sign.sh"

FROM=""
DEST=""

usage() {
    sed -n '/^# export-r610/,/^set -euo/p' "$0" | sed 's/^# \?//' | head -n -1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from) FROM="${2:-}"; shift 2 ;;
        --dest) DEST="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$FROM" ]]; then
    echo "export-r610-modules.sh: --from DIR is required (kernel-open or unsigned tree)" >&2
    exit 2
fi
[[ -d "$FROM" ]] || { echo "export-r610-modules.sh: not a directory: $FROM" >&2; exit 1; }

DEST="${DEST:-$(r610_staging_unsigned)}"
nvidia_version_load "$REPO_ROOT"
expected="$(nvidia_composed_module_version "$REPO_ROOT")"

missing=0
while IFS= read -r name; do
    if [[ ! -f "$FROM/$name" ]]; then
        echo "missing required $name in $FROM" >&2
        missing=1
    fi
done < <(r610_required_ko_names)
if [[ "$missing" -ne 0 ]]; then
    exit 1
fi

r610_export_modules "$FROM" "$DEST"
echo "exported unsigned modules → $DEST"
echo "  expected version $expected"
echo "  stock extra/nvidia/ was not modified"
echo "next: sudo $REPO_ROOT/scripts/sign-r610-modules.sh --from $DEST"
exit 0
