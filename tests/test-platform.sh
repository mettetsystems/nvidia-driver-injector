#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
. "$here/../tools/lib/platform.sh"

root="$(cd "$here/.." && pwd)"

os="$(mktemp -d)"
trap 'rm -rf "$os"' EXIT

printf 'ID=fedora\nVERSION_ID=44\n' > "$os/os-release"
platform_is_fedora44 "$os/os-release"
assert_eq "$?" "0" "recognise Fedora 44"

printf 'ID=fedora\nVERSION_ID=43\n' > "$os/os-release43"
platform_is_fedora44 "$os/os-release43"
assert_eq "$?" "1" "reject Fedora 43"

platform_kernel_supported "7.1.10-200.fc44.x86_64"
assert_eq "$?" "0" "7.1.10 is supported"
platform_kernel_supported "7.0.9-204.fc44.x86_64"
assert_eq "$?" "1" "7.0.x is not the R610 kernel series"

assert_eq "$(platform_gb202_device_id)" "0x2b85" "GB202 device id"
assert_eq "$(platform_bar1_min_bytes)" "34359738368" "BAR1 min 32 GiB"

# Mock sysfs: internal 2070 + GB202 whose real path parents a bridge
pci="$os/pci"
real="$os/real/0000:8c:00.0/0000:8d:00.0"
mkdir -p "$pci/0000:02:00.0" "$real" "$pci/0000:8c:00.0"
printf '0x10de\n' > "$pci/0000:02:00.0/vendor"
printf '0x1f07\n' > "$pci/0000:02:00.0/device"
printf '0x8086\n' > "$pci/0000:8c:00.0/vendor"
printf '0x0000\n' > "$pci/0000:8c:00.0/device"
printf '0x10de\n' > "$real/vendor"
printf '0x2b85\n' > "$real/device"
# BAR1 32 GiB: start 0, end 32GiB-1 on resource line 2
printf '0x0000000000000000 0x000000000fffffff 0x0000000000000200\n0x0000000000000000 0x00000007ffffffff 0x0000000000002206\n' \
    > "$real/resource"
ln -sfn "$real" "$pci/0000:8d:00.0"

gb="$(platform_find_gb202_bdfs "$pci")"
assert_eq "$gb" "0000:8d:00.0" "discover GB202 without hardcoded BDF"

bar="$(platform_bar1_bytes "$pci/0000:8d:00.0")"
assert_eq "$bar" "34359738368" "BAR1 bytes from mock resource"

br="$(platform_upstream_bridge_bdf "$pci/0000:8d:00.0")"
assert_eq "$br" "0000:8c:00.0" "upstream bridge from sysfs parent"

platform_has_non_gb202_nvidia "$pci"
assert_eq "$?" "0" "detect internal NVIDIA GPU"

plan="$(platform_compute_only_plan "$pci")"
assert_contains "$plan" "icd_disable=skip" "compute-only skips global ICD"
assert_contains "$plan" "audio_udev_device=10de:22e8" "audio udev stays 5090-scoped"
assert_contains "$plan" "drm_modeset=unchanged" "dual-GPU leaves nvidia_drm modeset alone"
assert_contains "$plan" "nvidia_autoload=enabled" "dual-GPU keeps nvidia autoload"
assert_contains "$plan" "compute_only_overlay=skip" "dual-GPU skips compute-only overlay"

# GB202 only — ICD apply
rm -rf "$pci/0000:02:00.0"
plan2="$(platform_compute_only_plan "$pci")"
assert_contains "$plan2" "icd_disable=apply" "egpu-only host may disable ICDs"
assert_contains "$plan2" "compute_only_overlay=apply" "egpu-only host gets compute-only overlay"
assert_contains "$plan2" "drm_modeset=0" "egpu-only host sets nvidia_drm modeset=0"

printf 'none [integrity] confidentiality\n' > "$os/ld"
assert_eq "$(platform_lockdown_mode "$os/ld")" "integrity" "lockdown parser integrity"
assert_eq "$(platform_h17_state_from integrity 0041)" "WRITE_BLOCKED" "H17 classifier WRITE_BLOCKED"

assert_eq "$(platform_h17_deployment_state integrity WRITE_BLOCKED 610.57.04 610.57.04-apnex.1)" \
    "STOCK_DRIVER_PENDING_A13" "deployment: stock under lockdown is PENDING"
assert_eq "$(platform_h17_deployment_state integrity PASS 610.57.04-apnex.1 610.57.04-apnex.1)" \
    "PATCHED_DRIVER_H17_PASS" "deployment: patched + PASS"
assert_eq "$(platform_h17_deployment_state integrity WRITE_BLOCKED 610.57.04-apnex.1 610.57.04-apnex.1)" \
    "PATCHED_DRIVER_H17_FAIL" "deployment: patched + not PASS is FAIL"

printf 'enabled\n' > "$os/sb"
assert_eq "$(platform_secure_boot_state "$os/sb")" "enabled" "secure boot fixture enabled"

assert_eq "$(platform_cmdline_profile 'BOOT iommu=pt quiet')" "f44-linux71" "iommu=pt profile"
assert_eq "$(platform_cmdline_profile 'BOOT iommu=off quiet')" "nuc-tb4" "iommu=off profile"
assert_eq "$(platform_cmdline_profile 'BOOT quiet')" "unknown" "unknown profile"

finish_tests
