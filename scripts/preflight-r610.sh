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
# shellcheck source=../tools/lib/module-sign.sh
. "$REPO_ROOT/tools/lib/module-sign.sh"

ok=0
warn=0
fail=0
ok()   { printf '  [OK]   %s\n' "$*"; ok=$((ok+1)); }
warn() { printf '  [WARN] %s\n' "$*"; warn=$((warn+1)); }
fail() { printf '  [FAIL] %s\n' "$*"; fail=$((fail+1)); }
info() { printf '  [INFO] %s\n' "$*"; }

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

sb="$(platform_secure_boot_state)"
h17_ld="$(platform_lockdown_mode)"
case "$h17_ld" in
    none)
        ok "kernel lockdown=none (userspace PCI config writes allowed)"
        us_h17="allowed (fallback)"
        ;;
    integrity|confidentiality)
        ok "kernel lockdown=$h17_ld (userspace setpci H17 is not authoritative)"
        info "do not disable Secure Boot or lockdown; production H17 is in-driver A13"
        us_h17="blocked by lockdown"
        ;;
    *)
        warn "kernel lockdown=$h17_ld (could not parse /sys/kernel/security/lockdown)"
        us_h17="unknown"
        ;;
esac
a13="$REPO_ROOT/patches/addon/A13-h17-bridge-cap.patch"
a13_status="missing"
if [[ -f "$a13" ]] && grep -q 'PCI_EXP_LNKCTL2_HASD' "$a13"; then
    ok "A13 in-driver H17 patch present (GB202-scoped)"
    a13_status="present"
else
    fail "A13-h17-bridge-cap.patch missing — userspace setpci cannot cap LnkCtl2 under lockdown"
fi
helper="$REPO_ROOT/scripts/host-files/usr/local/sbin/nvidia-driver-injector-bridge-link-cap"
if grep -q 'write_word' "$helper" && grep -q 'H17_WRITE_BLOCKED' "$helper"; then
    ok "userspace H17 helper fails closed on PCI write errors"
else
    fail "userspace H17 helper still ignores setpci write failures"
fi

h17_live="$(platform_h17_state)"
patched="$(nvidia_composed_module_version "$REPO_ROOT")"
loaded="$(nvidia_loaded_module_version)"
deploy="$(platform_h17_deployment_state "$h17_ld" "$h17_live" "$loaded" "$patched")"
h17_display="$h17_live"
readiness="FAIL"

case "$deploy" in
    STOCK_DRIVER_PENDING_A13)
        info "H17 pending A13 activation; stock module currently loaded ($loaded)."
        info "This is expected before Milestone B."
        h17_display="PENDING_A13"
        readiness="PASS for Milestone B"
        ;;
    PATCHED_DRIVER_H17_PASS)
        ok "patched driver $loaded; H17 readback verified"
        h17_display="PASS"
        readiness="PASS"
        ;;
    PATCHED_DRIVER_H17_FAIL)
        fail "patched driver loaded ($loaded) but H17 verification failed (H17=${h17_live})"
        h17_display="$h17_live"
        readiness="FAIL"
        ;;
esac
if [ "$a13_status" != "present" ]; then
    readiness="FAIL"
fi

if [ "$loaded" = "(not loaded)" ]; then
    warn "nvidia.ko not loaded (expected until Milestone B)"
else
    ok "nvidia.ko loaded version=$loaded (preflight does not unload it)"
fi

echo
echo "  --- H17 / Milestone B ---"
printf '  %-24s %s\n' "Secure Boot" "$sb"
printf '  %-24s %s\n' "kernel lockdown" "$h17_ld"
printf '  %-24s %s\n' "userspace H17" "$us_h17"
printf '  %-24s %s\n' "A13 kernel H17" "$a13_status"
printf '  %-24s %s\n' "loaded module" "$loaded"
printf '  %-24s %s\n' "live H17" "$h17_display"
printf '  %-24s %s\n' "H17 readiness" "$readiness"

sign_key="$(r610_mok_key_state)"
sign_cert="$(r610_mok_cert_state)"
sign_enrolled="$(r610_cert_enrolled_state)"
unsigned_dir="$(r610_staging_unsigned)"
signed_dir="$(r610_staging_signed)"
if [ "$(r610_modules_built_state "$signed_dir")" = "yes" ]; then
    sign_built="yes"
    sign_modules="$signed_dir"
elif [ "$(r610_modules_built_state "$unsigned_dir")" = "yes" ]; then
    sign_built="yes"
    sign_modules="$unsigned_dir"
else
    sign_built="no"
    sign_modules="$signed_dir"
fi
if [ "$sign_built" = "yes" ]; then
    sign_signed="$(r610_modules_signed_state "$sign_modules" "$patched")"
else
    sign_signed="PENDING"
fi
mb_ready="$(r610_milestone_b_sign_readiness "$sb" "$sign_key" "$sign_cert" "$sign_enrolled" "$sign_built" "$sign_signed")"

echo
echo "  --- Secure Boot signing / Milestone B ---"
printf '  %-24s %s\n' "Secure Boot" "$sb"
printf '  %-24s %s\n' "kernel lockdown" "$h17_ld"
printf '  %-24s %s\n' "signing private key" "$sign_key"
printf '  %-24s %s\n' "signing certificate" "$sign_cert"
printf '  %-24s %s\n' "certificate enrolled" "$sign_enrolled"
printf '  %-24s %s\n' "patched modules built" "$sign_built"
printf '  %-24s %s\n' "patched modules signed" "$sign_signed"
printf '  %-24s %s\n' "Milestone B readiness" "$mb_ready"

if [ "$sb" = "enabled" ]; then
    if [ "$sign_key" != "available" ]; then
        fail "signing private key unavailable under Secure Boot (akmods/DKMS/R610_MOK_KEY); do not disable Secure Boot"
    fi
    if [ "$sign_cert" != "available" ]; then
        fail "signing certificate unavailable under Secure Boot; do not disable Secure Boot"
    fi
    if [ "$sign_enrolled" != "PASS" ]; then
        fail "signing certificate is not enrolled in MOK; enroll it (mokutil --import), do not disable Secure Boot"
    fi
    if [ "$sign_signed" != "PASS" ]; then
        fail "patched modules are not a fully signed set (H17 A13 requires signed nvidia.ko under Secure Boot)"
    fi
fi
if [ "$mb_ready" != "PASS" ] && [ "$sb" = "enabled" ]; then
    info "build-only/sign-only: scripts/export-r610-modules.sh then scripts/sign-r610-modules.sh"
fi

fw="/lib/firmware/nvidia/${NVIDIA_OPEN_TAG}"
if [ -s "$fw/gsp_ga10x.bin" ]; then
    ok "GSP firmware present at $fw"
else
    warn "GSP firmware missing at $fw (needed at module load)"
fi

echo
echo "preflight: $ok ok, $warn warn, $fail fail"
[ "$fail" -eq 0 ]
