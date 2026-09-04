#!/usr/bin/env bash
# Dual-GPU Layer-1: mock sysfs only. No GPU, no insmod, no /etc writes.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
. "$here/../tools/lib/platform.sh"

root="$(cd "$here/.." && pwd)"
base="$root/scripts/host-files/etc/modprobe.d/nvidia-driver-injector.conf"
overlay="$root/scripts/host-files/etc/modprobe.d/nvidia-driver-injector-compute-only.conf"

os="$(mktemp -d)"
trap 'rm -rf "$os"' EXIT

# Mock sysfs: internal 2070 (0x1f07) + GB202 (0x2b85). BDFs are fixtures.
pci="$os/pci"
mkdir -p "$pci/0000:02:00.0" "$pci/0000:8d:00.0"
printf '0x10de\n' > "$pci/0000:02:00.0/vendor"
printf '0x1f07\n' > "$pci/0000:02:00.0/device"
printf '0x10de\n' > "$pci/0000:8d:00.0/vendor"
printf '0x2b85\n' > "$pci/0000:8d:00.0/device"

# --- repo conf files ---
platform_conf_has_egpu_only_globals "$base"
assert_eq "$?" "1" "base modprobe.d has no eGPU-only globals"

if grep -vE '^[[:space:]]*(#|$)' "$base" | grep -Eq 'blacklist|install nvidia|/bin/false|modeset=0|RmForceExternalGpu|PreserveVideoMemoryAllocations'; then
    assert_eq "dirty" "clean" "base conf has none of blacklist/modeset=0/RmForceExternalGpu/PreserveVideo"
else
    assert_eq "1" "1" "base conf has none of blacklist/modeset=0/RmForceExternalGpu/PreserveVideo"
fi

platform_conf_has_egpu_only_globals "$overlay"
assert_eq "$?" "0" "compute-only overlay has eGPU-only globals"

assert_file_contains "$overlay" "blacklist nvidia" "overlay blacklists nvidia"
assert_file_contains "$overlay" "modeset=0" "overlay sets nvidia_drm modeset=0"
assert_file_contains "$base" "NVreg_TbEgpuRecoverEnable=1" "base keeps RecoverEnable"

# Fake blacklist conf — the condition preflight FAILs on
bad="$os/bad-nvidia.conf"
cat > "$bad" <<'EOF'
# would break the internal GPU
blacklist nvidia
install nvidia /bin/false
options nvidia_drm modeset=0 fbdev=0
options nvidia NVreg_RegistryDwords="RmForceExternalGpu=1"
EOF
platform_conf_has_egpu_only_globals "$bad"
assert_eq "$?" "0" "preflight would FAIL a fake conf with blacklist/modeset=0/RmForceExternalGpu"

# Comments-only file is not an eGPU-only global
ok_cmt="$os/comments.conf"
printf '# blacklist nvidia\n# modeset=0\n' > "$ok_cmt"
platform_conf_has_egpu_only_globals "$ok_cmt"
assert_eq "$?" "1" "comment-only conf is not eGPU-only global"

# --- plan + operator report (mock sysfs) ---
plan="$(platform_compute_only_plan "$pci")"
assert_contains "$plan" "icd_disable=skip" "dual-GPU plan skips ICD disable"
assert_contains "$plan" "drm_modeset=unchanged" "dual-GPU plan leaves drm modeset"
assert_contains "$plan" "nvidia_autoload=enabled" "dual-GPU plan keeps autoload"
assert_contains "$plan" "compute_only_overlay=skip" "dual-GPU plan skips overlay"
assert_contains "$plan" "tb_egpu_recover=enabled" "dual-GPU plan keeps TbEgpu recover"
assert_contains "$plan" "audio_udev_device=10de:22e8" "audio stays 5090-scoped"

report="$(platform_print_layer1_gpu_report "$pci")"
assert_contains "$report" "Internal RTX 2070:" "report has 2070 section"
assert_contains "$report" "nvidia                 enabled" "2070 nvidia enabled"
assert_contains "$report" "nvidia_modeset         enabled" "2070 nvidia_modeset enabled"
assert_contains "$report" "nvidia_drm             enabled/unchanged" "2070 nvidia_drm unchanged"
assert_contains "$report" "graphics ICDs          unchanged" "2070 ICDs unchanged"
assert_contains "$report" "External RTX 5090:" "report has 5090 section"
assert_contains "$report" "compute-only           enabled" "5090 compute-only"
assert_contains "$report" "HDMI audio             disabled" "5090 HDMI audio disabled"
assert_contains "$report" "D3cold protection      enabled" "5090 D3cold protection"
assert_contains "$report" "TbEgpu recovery        enabled" "5090 TbEgpu recovery"

# --- apply.sh dry-run selection (PLATFORM_PCI_ROOT; --no-act; no root) ---
export PLATFORM_PCI_ROOT="$pci"
out="$(bash "$root/scripts/apply.sh" --no-act --skip-cmdline --skip-icd --skip-k3s 2>&1 || true)"
assert_contains "$out" "not installing compute-only overlay" "apply --no-act skips overlay on dual-GPU mock"
assert_contains "$out" "rm -f /etc/modprobe.d/nvidia-driver-injector-compute-only.conf" \
    "apply --no-act would remove leftover overlay on dual-GPU"

inst="$(bash "$root/scripts/install-r610.sh" --dry-run 2>&1 || true)"
assert_contains "$inst" "nvidia                 enabled" "install-r610 dry-run 2070 nvidia enabled"
assert_contains "$inst" "graphics ICDs          unchanged" "install-r610 dry-run ICDs unchanged"
assert_contains "$inst" "compute-only           enabled" "install-r610 dry-run 5090 compute-only"
unset PLATFORM_PCI_ROOT

# eGPU-only mock: overlay would apply
rm -rf "$pci/0000:02:00.0"
plan_e="$(platform_compute_only_plan "$pci")"
assert_contains "$plan_e" "compute_only_overlay=apply" "eGPU-only plan applies overlay"

export PLATFORM_PCI_ROOT="$pci"
out_e="$(bash "$root/scripts/apply.sh" --no-act --skip-cmdline --skip-icd --skip-k3s 2>&1 || true)"
assert_contains "$out_e" "installing compute-only overlay" "apply --no-act installs overlay on eGPU-only mock"
unset PLATFORM_PCI_ROOT

# --- in-driver GB202 gates (patch text; no compile) ---
assert_file_contains "$root/patches/addon/A2-bus-loss-watchdog.patch" \
    'tb_egpu_qwd_is_gb202' "A2 gates Q-watchdog on GB202"
assert_file_contains "$root/patches/addon/A2-bus-loss-watchdog.patch" \
    '0x2b85' "A2 names PCI device 0x2b85"
assert_file_contains "$root/patches/addon/A3-recovery.patch" \
    'tb_egpu_pci_is_gb202' "A3 gates recovery/AER on GB202"
assert_file_contains "$root/patches/addon/A3-recovery.patch" \
    'pdev->device == 0x2b85' "A3 matches GB202 device id"

finish_tests
