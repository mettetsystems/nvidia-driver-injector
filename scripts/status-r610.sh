#!/usr/bin/env bash
# status-r610.sh — read-only R610 view, then the existing status.sh.
# Never mutates the host.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../tools/lib/nvidia-version.sh
. "$REPO_ROOT/tools/lib/nvidia-version.sh"
# shellcheck source=../tools/lib/platform.sh
. "$REPO_ROOT/tools/lib/platform.sh"
# shellcheck source=../tools/lib/module-sign.sh
. "$REPO_ROOT/tools/lib/module-sign.sh"

nvidia_version_load "$REPO_ROOT"
composed="$(nvidia_composed_module_version "$REPO_ROOT")"

echo "== R610 status =="
echo "  NVIDIA_OPEN_TAG=$NVIDIA_OPEN_TAG"
echo "  expected module string=$composed"
echo "  kernel=$(uname -r)"
echo "  cmdline profile=$(platform_cmdline_profile)"
echo "  Fedora 44=$(platform_is_fedora44 && echo yes || echo no)"
echo "  GB202 BDFs:"
mapfile -t gb < <(platform_find_gb202_bdfs || true)
if [[ ${#gb[@]} -eq 0 ]]; then
    echo "    (none)"
else
    for b in "${gb[@]}"; do
        bar="$(platform_bar1_bytes "/sys/bus/pci/devices/$b" 2>/dev/null || echo 0)"
        br="$(platform_upstream_bridge_bdf "/sys/bus/pci/devices/$b" 2>/dev/null || echo unknown)"
        echo "    $b  BAR1=${bar}  bridge=$br"
    done
fi
echo "  lockdown=$(platform_lockdown_mode)"
echo "  H17=$(platform_h17_state)"
echo "  compute-only plan:"
platform_compute_only_plan | sed 's/^/    /'
echo "  Secure Boot=$(platform_secure_boot_state)"
echo "  signing key=$(r610_mok_key_state)"
echo "  signing cert=$(r610_mok_cert_state)"
echo "  certificate enrolled=$(r610_cert_enrolled_state)"
if grep -E '^nvidia ' /proc/modules >/dev/null 2>&1; then
    echo "  loaded nvidia version=$(modinfo -F version nvidia 2>/dev/null || echo unknown)"
    echo "  loaded module signatures:"
    for short in nvidia nvidia_modeset nvidia_drm nvidia_uvm nvidia_peermem; do
        ver="$(r610_loaded_module_version_of "$short" 2>/dev/null || true)"
        [ -n "$ver" ] || continue
        signer="$(r610_loaded_module_signer "$short" 2>/dev/null || true)"
        if [ -z "$signer" ]; then
            echo "    $short version=$ver UNSIGNED"
        else
            echo "    $short version=$ver signer=$signer"
        fi
    done
else
    echo "  loaded nvidia version=(not loaded)"
fi
echo

exec "$REPO_ROOT/scripts/status.sh"
