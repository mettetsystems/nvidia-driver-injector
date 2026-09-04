# Host platform helpers (no GPU required for the parsers; sysfs walk
# needs a fake tree for tests).

platform_os_id() {
    local f="${1:-/etc/os-release}"
    [ -r "$f" ] || return 1
    awk -F= '/^ID=/{gsub(/"/,"",$2); print $2; exit}' "$f"
}

platform_os_version_id() {
    local f="${1:-/etc/os-release}"
    [ -r "$f" ] || return 1
    awk -F= '/^VERSION_ID=/{gsub(/"/,"",$2); print $2; exit}' "$f"
}

platform_is_fedora44() {
    [ "$(platform_os_id "${1:-/etc/os-release}")" = "fedora" ] || return 1
    [ "$(platform_os_version_id "${1:-/etc/os-release}")" = "44" ] || return 1
}

# Kernel series 7.1.x is the R610 branch target. Other 7.x kernels warn.
platform_kernel_supported() {
    local kver="${1:-$(uname -r)}"
    case "$kver" in
        7.1.*) return 0 ;;
        *) return 1 ;;
    esac
}

# GB202 RTX 5090 PCI device id.
platform_gb202_device_id() { echo "0x2b85"; }
platform_nvidia_vendor_id() { echo "0x10de"; }

# Walk a sysfs pci devices dir (default /sys/bus/pci/devices).
# Prints BDFs whose vendor/device match GB202. No hardcoded BDF.
platform_find_gb202_bdfs() {
    local pci_root="${1:-/sys/bus/pci/devices}"
    local want_v want_d v d bdf
    want_v="$(platform_nvidia_vendor_id)"
    want_d="$(platform_gb202_device_id)"
    [ -d "$pci_root" ] || return 0
    for dpath in "$pci_root"/*; do
        [ -r "$dpath/vendor" ] && [ -r "$dpath/device" ] || continue
        v="$(cat "$dpath/vendor" 2>/dev/null || true)"
        d="$(cat "$dpath/device" 2>/dev/null || true)"
        if [ "$v" = "$want_v" ] && [ "$d" = "$want_d" ]; then
            bdf="$(basename "$dpath")"
            printf '%s\n' "$bdf"
        fi
    done
}

# BAR1 size in bytes from a sysfs device dir (resource line 2).
platform_bar1_bytes() {
    local devdir="$1"
    local start end
    [ -r "$devdir/resource" ] || { echo 0; return 1; }
    read -r start end _ < <(awk 'NR==2 {print $1, $2}' "$devdir/resource")
    [ -n "$start" ] && [ -n "$end" ] || { echo 0; return 1; }
    printf '%d\n' $((end - start + 1))
}

platform_bar1_min_bytes() {
    echo 34359738368  # 32 GiB
}

# Parent bridge of a PCI device via sysfs (basename of .../device/..).
platform_upstream_bridge_bdf() {
    local devdir="$1"
    local parent
    [ -e "$devdir" ] || return 1
    parent="$(readlink -f "$devdir/..")"
    basename "$parent"
}

# Print BDFs of every NVIDIA function (vendor 0x10de), any device id.
platform_find_nvidia_bdfs() {
    local pci_root="${1:-/sys/bus/pci/devices}"
    local want_v v bdf
    want_v="$(platform_nvidia_vendor_id)"
    [ -d "$pci_root" ] || return 0
    for dpath in "$pci_root"/*; do
        [ -r "$dpath/vendor" ] || continue
        v="$(cat "$dpath/vendor" 2>/dev/null || true)"
        if [ "$v" = "$want_v" ]; then
            bdf="$(basename "$dpath")"
            printf '%s\n' "$bdf"
        fi
    done
}

# True if a non-GB202 NVIDIA device is present (typically an internal
# display GPU such as RTX 2070). Used to refuse global ICD disable.
platform_has_non_gb202_nvidia() {
    local pci_root="${1:-/sys/bus/pci/devices}"
    local want_v want_d v d
    want_v="$(platform_nvidia_vendor_id)"
    want_d="$(platform_gb202_device_id)"
    [ -d "$pci_root" ] || return 1
    for dpath in "$pci_root"/*; do
        [ -r "$dpath/vendor" ] && [ -r "$dpath/device" ] || continue
        v="$(cat "$dpath/vendor" 2>/dev/null || true)"
        d="$(cat "$dpath/device" 2>/dev/null || true)"
        if [ "$v" = "$want_v" ] && [ "$d" != "$want_d" ]; then
            return 0
        fi
    done
    return 1
}

# Compute-only plan for this host. Prints key=value lines.
# audio_udev is always scoped to the 5090 HDMI audio id (10de:22e8).
# icd_disable is "skip" when an internal NVIDIA GPU is present.
platform_compute_only_plan() {
    local pci_root="${1:-/sys/bus/pci/devices}"
    printf 'audio_udev_device=10de:22e8\n'
    if platform_has_non_gb202_nvidia "$pci_root"; then
        printf 'icd_disable=skip\n'
        printf 'icd_reason=internal-nvidia-display-gpu\n'
    else
        printf 'icd_disable=apply\n'
        printf 'icd_reason=egpu-only\n'
    fi
}

# cmdline profile: "f44-linux71" | "nuc-tb4" | "unknown"
platform_cmdline_profile() {
    local cmdline="${1:-}"
    [ -n "$cmdline" ] || cmdline="$(cat /proc/cmdline 2>/dev/null || true)"
    case " $cmdline " in
        *" iommu=pt "*) echo f44-linux71 ;;
        *" iommu=off "*) echo nuc-tb4 ;;
        *) echo unknown ;;
    esac
}

# Tokens that must not be written onto a Fedora 44 + 7.1 reference host.
platform_f44_linux71_forbidden_cmdline_tokens() {
    printf '%s\n' iommu=off intel_iommu=off
}
