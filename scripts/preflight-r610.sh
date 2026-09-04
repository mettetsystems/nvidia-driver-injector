#!/usr/bin/env bash
# preflight-r610.sh — read-only checks for the R610 / Linux 7.1 rebase.
# Never mutates the host. Safe to run any time.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../tools/lib/nvidia-version.sh
. "$REPO_ROOT/tools/lib/nvidia-version.sh"
# shellcheck source=../tools/lib/platform.sh
. "$REPO_ROOT/tools/lib/platform.sh"
. "$REPO_ROOT/tools/lib/manifest.sh"

ok=0
warn=0
fail=0
ok()   { printf '  [OK]   %s\n' "$*"; ok=$((ok+1)); }
warn() { printf '  [WARN] %s\n' "$*"; warn=$((warn+1)); }
fail() { printf '  [FAIL] %s\n' "$*"; fail=$((fail+1)); }

echo "== R610 preflight (read-only) =="

nvidia_version_load "$REPO_ROOT"
ok "nvidia-version.env NVIDIA_OPEN_TAG=$NVIDIA_OPEN_TAG"
nvidia_assert_dockerfile_aligned "$REPO_ROOT"
ok "Dockerfile ARG NVIDIA_OPEN_TAG matches nvidia-version.env"

if [ -L "$REPO_ROOT/Containerfile" ]; then
    ok "Containerfile -> Dockerfile"
else
    fail "Containerfile is not a symlink to Dockerfile"
fi

if platform_kernel_supported "$(uname -r)"; then
    ok "kernel $(uname -r) is 7.1.x"
else
    warn "kernel $(uname -r) is not 7.1.x (R610 branch target)"
fi

if platform_is_fedora44; then
    ok "OS is Fedora 44"
else
    warn "OS is not Fedora 44 (ID=$(platform_os_id || echo unknown))"
fi

profile="$(platform_cmdline_profile)"
case "$profile" in
    f44-linux71) ok "cmdline profile iommu=pt (Fedora 44 / 7.1)" ;;
    nuc-tb4)     ok "cmdline profile iommu=off (NUC / TB4)" ;;
    *)           warn "cmdline profile unknown (no iommu=pt or iommu=off)" ;;
esac

if [ "$profile" = "f44-linux71" ] && [ -d /sys/class/iommu/dmar0 ]; then
    ok "dmar0 present under iommu=pt (expected)"
fi

manifest="$REPO_ROOT/patches/manifest"
manifest_lint "$manifest"
ok "patches/manifest lints"

rows=0
while read -r id layer _ _; do
    [ -n "${id:-}" ] || continue
    f="$REPO_ROOT/patches/$layer/$id.patch"
    if [ -f "$f" ]; then
        rows=$((rows+1))
    else
        fail "missing patch file $f"
    fi
done < <(manifest_rows "$manifest")
ok "production patch files present ($rows rows)"

if grep -q 'NVIDIA_VERSION = 610.57.04-apnex.1' "$REPO_ROOT/patches/addon/A5-version-and-toggles.patch"; then
    ok "A5 stamps 610.57.04-apnex.1"
else
    fail "A5 does not stamp 610.57.04-apnex.1"
fi

if grep -F -- '-ccflags-y += -DNV_VERSION_STRING=\"610.57.04\"' "$REPO_ROOT/patches/base/C1-kbuild-version-mk.patch" >/dev/null; then
    ok "C1 minus-line targets 610.57.04"
else
    fail "C1 minus-line is not 610.57.04"
fi

gb202="$(platform_find_gb202_bdfs || true)"
if [ -n "$gb202" ]; then
    ok "GB202 discovered: $(printf '%s' "$gb202" | tr '\n' ' ')"
    first="$(printf '%s\n' "$gb202" | head -n1)"
    bar="$(platform_bar1_bytes "/sys/bus/pci/devices/$first" || echo 0)"
    min="$(platform_bar1_min_bytes)"
    if [ "$bar" -ge "$min" ]; then
        ok "BAR1 $bar >= $min"
    else
        warn "BAR1 $bar < $min (32 GiB) for $first"
    fi
    br="$(platform_upstream_bridge_bdf "/sys/bus/pci/devices/$first" || true)"
    [ -n "$br" ] && ok "upstream bridge $br" || warn "could not resolve upstream bridge"
else
    warn "no GB202 (10de:2b85) on PCI (eGPU unplugged?)"
fi

if platform_has_non_gb202_nvidia; then
    ok "internal NVIDIA GPU present — ICD disable must stay skipped"
    base_conf="$REPO_ROOT/scripts/host-files/etc/modprobe.d/nvidia-driver-injector.conf"
    if platform_conf_has_egpu_only_globals "$base_conf"; then
        fail "repo base modprobe.d still has eGPU-only globals (would disable the internal GPU)"
    else
        ok "repo base modprobe.d has no eGPU-only globals"
    fi
    overlay="$REPO_ROOT/scripts/host-files/etc/modprobe.d/nvidia-driver-injector-compute-only.conf"
    if [[ -f "$overlay" ]] && platform_conf_has_egpu_only_globals "$overlay"; then
        ok "compute-only overlay exists (eGPU-only hosts only)"
    else
        fail "compute-only overlay missing or empty"
    fi
    if [[ -f /etc/modprobe.d/nvidia-driver-injector.conf ]] && \
       platform_conf_has_egpu_only_globals /etc/modprobe.d/nvidia-driver-injector.conf; then
        fail "installed /etc/modprobe.d/nvidia-driver-injector.conf has eGPU-only globals"
    fi
    if [[ -f /etc/modprobe.d/nvidia-driver-injector-compute-only.conf ]]; then
        fail "installed compute-only overlay while an internal NVIDIA GPU is present"
    fi
else
    warn "no internal NVIDIA GPU seen (ICD disable would be global)"
fi

fw="/lib/firmware/nvidia/${NVIDIA_OPEN_TAG}"
if [ -s "$fw/gsp_ga10x.bin" ]; then
    ok "GSP firmware present at $fw"
else
    warn "GSP firmware missing at $fw (needed at module load)"
fi

if grep -E '^nvidia ' /proc/modules >/dev/null 2>&1; then
    ver="$(modinfo -F version nvidia 2>/dev/null || echo unknown)"
    ok "nvidia.ko loaded version=$ver (preflight does not unload it)"
else
    warn "nvidia.ko not loaded (expected until Milestone B)"
fi

echo
echo "preflight: $ok ok, $warn warn, $fail fail"
[ "$fail" -eq 0 ]
