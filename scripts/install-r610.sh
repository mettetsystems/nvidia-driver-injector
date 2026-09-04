#!/usr/bin/env bash
# install-r610.sh — Layer 1 helper for the R610 branch.
#
# Default: dry-run. Never loads nvidia.ko.
#
#   ./scripts/install-r610.sh              # dry-run
#   ./scripts/install-r610.sh --apply      # Layer 1 only (safe flags)
#   ./scripts/install-r610.sh --load-module
#       prints the five-point gate and exits 78. Does not insmod.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../tools/lib/platform.sh
. "$REPO_ROOT/tools/lib/platform.sh"
# shellcheck source=../tools/lib/nvidia-version.sh
. "$REPO_ROOT/tools/lib/nvidia-version.sh"

DRY_RUN=1
APPLY=0
LOAD_MODULE=0
ACCEPT_KERNEL_RISK=0

usage() {
    sed -n '/^# install-r610/,/^set -euo/p' "$0" | sed 's/^# \?//' | head -n -1
}

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --apply) APPLY=1; DRY_RUN=0 ;;
        --load-module) LOAD_MODULE=1 ;;
        --i-accept-host-kernel-risk) ACCEPT_KERNEL_RISK=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

nvidia_version_load "$REPO_ROOT"
composed="$(nvidia_composed_module_version "$REPO_ROOT")"

echo "== install-r610 (NVIDIA $NVIDIA_OPEN_TAG → $composed) =="

apply_flags=(--skip-k3s)
if platform_is_fedora44 && platform_kernel_supported "$(uname -r)"; then
    apply_flags+=(--skip-cmdline)
    echo "  platform Fedora 44 + 7.1: will not touch kernel cmdline"
fi
if platform_has_non_gb202_nvidia; then
    apply_flags+=(--skip-icd)
    echo "  internal NVIDIA GPU: will not disable ICDs"
fi

echo
echo "Would run Layer 1:"
echo "  sudo $REPO_ROOT/scripts/apply.sh ${apply_flags[*]}"

if [[ "$APPLY" -eq 1 ]]; then
    if [[ "$EUID" -ne 0 ]]; then
        echo "install-r610 --apply must be run as root" >&2
        exit 1
    fi
    echo
    echo "Applying Layer 1 with ${apply_flags[*]} ..."
    "$REPO_ROOT/scripts/apply.sh" "${apply_flags[@]}"
else
    echo
    echo "[dry-run] not calling apply.sh (pass --apply)"
    "$REPO_ROOT/scripts/apply.sh" --no-act "${apply_flags[@]}" || true
fi

echo
if [[ "$LOAD_MODULE" -eq 1 ]]; then
    echo "===== LIVE KERNEL GATE ====="
    echo "1. command:     (NOT EXECUTED) modprobe nvidia  # or injector entrypoint"
    echo "2. effect:      replace/load nvidia.ko $composed into the running kernel"
    echo "3. rollback:    rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia ; restore stock 610.57.04"
    echo "4. risk:        host freeze, display loss on RTX 2070, unbootable if firmware missing"
    echo "5. verify:      modinfo nvidia ; nvidia-smi ; BAR1 32 GiB"
    echo
    if [[ "$ACCEPT_KERNEL_RISK" -ne 1 ]]; then
        echo "refusing: pass --i-accept-host-kernel-risk as well. Still will not execute the load."
    else
        echo "acknowledged, but this script still will not execute the load."
        echo "A human must run the injector entrypoint / modprobe after reading docs/r610-rollback.md."
    fi
    exit 78
fi

echo "install-r610: no module load (Milestone A). See docs/r610-rollback.md."
exit 0
