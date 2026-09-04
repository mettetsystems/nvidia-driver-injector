#!/usr/bin/env bash
# remove-r610.sh — reverse install-r610.sh. Default dry-run.
# Never unloads nvidia.ko or rewrites the bootloader unless the operator
# passes danger flags; even then grubby/rmmod are not executed here.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DRY_RUN=1
APPLY=0
UNLOAD=0
REVERT_CMDLINE=0
ACCEPT_KERNEL_RISK=0

usage() {
    sed -n '/^# remove-r610/,/^set -euo/p' "$0" | sed 's/^# \?//' | head -n -1
}

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --apply) APPLY=1; DRY_RUN=0 ;;
        --unload-module) UNLOAD=1 ;;
        --revert-cmdline) REVERT_CMDLINE=1 ;;
        --i-accept-host-kernel-risk) ACCEPT_KERNEL_RISK=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

echo "== remove-r610 =="
echo "Would run Layer 1 reverse:"
echo "  sudo $REPO_ROOT/scripts/remove.sh --no-act"

if [[ "$APPLY" -eq 1 ]]; then
    if [[ "$EUID" -ne 0 ]]; then
        echo "remove-r610 --apply must be run as root" >&2
        exit 1
    fi
    # Never imply --revert-cmdline or --purge from this wrapper.
    "$REPO_ROOT/scripts/remove.sh"
else
    echo "[dry-run] not calling remove.sh (pass --apply)"
    "$REPO_ROOT/scripts/remove.sh" --no-act || true
fi

gate() {
    echo "===== LIVE KERNEL GATE ====="
    echo "1. command:     $1"
    echo "2. effect:      $2"
    echo "3. rollback:    $3"
    echo "4. risk:        $4"
    echo "5. verify:      $5"
    echo "This wrapper does not execute that command."
}

if [[ "$UNLOAD" -eq 1 ]]; then
    gate \
        "rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia  # or injector uninstall" \
        "unload the live NVIDIA stack" \
        "reload the last known-good 610.57.04 module" \
        "display loss, leftover /dev/nvidia*, host freeze if refcnt>0" \
        "lsmod | grep nvidia ; test -e /dev/nvidia0 && echo still-present"
    [[ "$ACCEPT_KERNEL_RISK" -eq 1 ]] || echo "also missing --i-accept-host-kernel-risk"
    exit 78
fi

if [[ "$REVERT_CMDLINE" -eq 1 ]]; then
    gate \
        "grubby --update-kernel=ALL --remove-args='…'" \
        "strip injector/NUC cmdline tokens" \
        "restore the known-good iommu=pt line; reboot" \
        "BAR1 collapse, D3cold failure, unbootable GPU topology" \
        "cat /proc/cmdline after reboot"
    [[ "$ACCEPT_KERNEL_RISK" -eq 1 ]] || echo "also missing --i-accept-host-kernel-risk"
    echo "On Fedora 44 + 7.1 do NOT strip iommu=pt / hpbussize / pcie_aspm=off."
    exit 78
fi

echo "remove-r610: no module unload, no cmdline revert."
exit 0
