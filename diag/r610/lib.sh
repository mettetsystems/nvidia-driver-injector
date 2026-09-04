#!/usr/bin/env bash
# Shared helpers for diag/r610 operator scripts.
set -euo pipefail

R610_DIAG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$R610_DIAG_DIR/../.." && pwd)"
# shellcheck source=../../tools/lib/platform.sh
. "$REPO_ROOT/tools/lib/platform.sh"

r610_log() { printf '%s\n' "$*"; }
r610_die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

r610_flush() { python3 -c 'import sys; sys.stdout.flush(); sys.stderr.flush()' 2>/dev/null || true; }

r610_discover_bdf() {
    if [[ -n "${EGPU_BDF:-}" ]]; then
        printf '%s\n' "$EGPU_BDF"
        return 0
    fi
    local b
    b="$(platform_find_gb202_bdfs | head -n1 || true)"
    [[ -n "$b" ]] || r610_die "no GB202 (10de:2b85) found; set EGPU_BDF"
    printf '%s\n' "$b"
}

r610_dump_kernel() {
    echo "----- kernel crumbs (NVRM|Xid|AER|GPPut|WATCHDOG) -----"
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -k -n 120 --no-pager 2>/dev/null | grep -E 'NVRM|Xid|AER|GPPut|WATCHDOG|nvidia' || true
    else
        dmesg 2>/dev/null | tail -n 120 | grep -E 'NVRM|Xid|AER|GPPut|WATCHDOG|nvidia' || true
    fi
    echo "----- end crumbs -----"
}

r610_refuse_stage4b() {
    if [[ "${I_ACCEPT_HOST_FREEZE_RISK:-}" != "1" ]]; then
        cat >&2 <<'EOF'
REFUSED: this stage froze the host on stock NVIDIA 610.57.04
(CUDA 719 + GPPut < WATCHDOG_GPFIFO_ENTRIES).

Set I_ACCEPT_HOST_FREEZE_RISK=1 and re-run as a human operator.
See docs/r610-test-plan.md and docs/r610-watchdog-analysis.md.
EOF
        exit 78
    fi
}

r610_require_driver() {
    grep -E '^nvidia ' /proc/modules >/dev/null 2>&1 \
        || r610_die "nvidia.ko is not loaded"
}

r610_cuda() {
    local stage="$1"
    shift
    python3 "$R610_DIAG_DIR/cuda_ladder.py" --stage "$stage" "$@"
}
