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

# Sysfs PCI devices dir. Tests set PLATFORM_PCI_ROOT to a mock tree.
platform_pci_root() {
    if [ -n "${1:-}" ]; then
        printf '%s\n' "$1"
    else
        printf '%s\n' "${PLATFORM_PCI_ROOT:-/sys/bus/pci/devices}"
    fi
}

# Walk a sysfs pci devices dir (default /sys/bus/pci/devices).
# Prints BDFs whose vendor/device match GB202. No hardcoded BDF.
platform_find_gb202_bdfs() {
    local pci_root
    pci_root="$(platform_pci_root "${1:-}")"
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
    local pci_root
    pci_root="$(platform_pci_root "${1:-}")"
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
    local pci_root
    pci_root="$(platform_pci_root "${1:-}")"
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
# drm_modeset/nvidia_autoload stay enabled on dual-GPU; compute-only
# overlay is only for eGPU-only hosts.
platform_compute_only_plan() {
    local pci_root
    pci_root="$(platform_pci_root "${1:-}")"
    printf 'audio_udev_device=10de:22e8\n'
    printf 'tb_egpu_recover=enabled\n'
    printf 'd3cold_protection=enabled\n'
    if platform_has_non_gb202_nvidia "$pci_root"; then
        printf 'icd_disable=skip\n'
        printf 'icd_reason=internal-nvidia-display-gpu\n'
        printf 'drm_modeset=unchanged\n'
        printf 'nvidia_autoload=enabled\n'
        printf 'compute_only_overlay=skip\n'
    else
        printf 'icd_disable=apply\n'
        printf 'icd_reason=egpu-only\n'
        printf 'drm_modeset=0\n'
        printf 'nvidia_autoload=blocked\n'
        printf 'compute_only_overlay=apply\n'
    fi
}

# True if a modprobe.d snippet uses eGPU-only globals that would break
# an internal NVIDIA display GPU. Ignores comments and blank lines.
platform_conf_has_egpu_only_globals() {
    local f="$1"
    [ -f "$f" ] || return 1
    grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null | grep -Eq \
        -e '^[[:space:]]*blacklist[[:space:]]+nvidia' \
        -e '^[[:space:]]*install[[:space:]]+nvidia' \
        -e 'modeset=0' \
        -e 'RmForceExternalGpu'
}

# Operator-facing Layer-1 plan. pci_root is mockable for tests.
platform_print_layer1_gpu_report() {
    local pci_root
    pci_root="$(platform_pci_root "${1:-}")"
    if platform_has_non_gb202_nvidia "$pci_root"; then
        cat <<'EOF'
Internal RTX 2070:
    nvidia                 enabled
    nvidia_modeset         enabled
    nvidia_drm             enabled/unchanged
    graphics ICDs          unchanged
EOF
    else
        cat <<'EOF'
Internal RTX 2070:
    (not present — eGPU-only host; compute-only overlay would apply)
EOF
    fi
    cat <<'EOF'
External RTX 5090:
    compute-only           enabled
    HDMI audio             disabled
    D3cold protection      enabled
    TbEgpu recovery        enabled
EOF
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

# Current kernel lockdown mode from /sys/kernel/security/lockdown.
# File format: "none [integrity] confidentiality" — bracketed token is active.
# Prints none | integrity | confidentiality | unknown
platform_lockdown_mode() {
    local f="${1:-${LOCKDOWN_FILE:-/sys/kernel/security/lockdown}}"
    local raw
    [ -r "$f" ] || { printf 'unknown\n'; return 0; }
    raw="$(tr -d '\n' < "$f")"
    if [[ "$raw" =~ \[([a-z]+)\] ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    printf 'unknown\n'
}

# Classify H17 from lockdown + LnkCtl2 hex (no PCI writes).
# Prints WRITE_BLOCKED | VERIFY_FAILED | PASS
# Optional target speed (default 3). bit5 must be 1 and TLS must match.
platform_h17_state_from() {
    local mode="$1"
    local hex="$2"
    local want="${3:-3}"
    local int target bit5
    hex="${hex#0x}"
    if [ -z "$hex" ]; then
        if [ "$mode" != "none" ] && [ "$mode" != "unknown" ]; then
            printf 'WRITE_BLOCKED\n'
        else
            printf 'VERIFY_FAILED\n'
        fi
        return 0
    fi
    int=$((16#$hex))
    target=$(( int & 0xF ))
    bit5=$(( (int >> 5) & 1 ))
    if [ "$bit5" -eq 1 ] && [ "$target" -eq "$want" ]; then
        printf 'PASS\n'
        return 0
    fi
    if [ "$mode" != "none" ] && [ "$mode" != "unknown" ]; then
        printf 'WRITE_BLOCKED\n'
        return 0
    fi
    printf 'VERIFY_FAILED\n'
}

# Live H17 classifier (read-only setpci). Optional bridge BDF.
platform_h17_state() {
    local bridge="${1:-}"
    local mode hex
    local setpci_bin="${SETPCI:-setpci}"
    mode="$(platform_lockdown_mode)"
    if [ -z "$bridge" ]; then
        local bdfs first
        bdfs="$(platform_find_gb202_bdfs || true)"
        first="$(printf '%s\n' "$bdfs" | head -n1)"
        if [ -n "$first" ]; then
            bridge="$(platform_upstream_bridge_bdf "/sys/bus/pci/devices/$first" 2>/dev/null || true)"
        fi
    fi
    if [ -n "$bridge" ]; then
        hex="$("$setpci_bin" -s "$bridge" CAP_EXP+0x30.W 2>/dev/null || true)"
    fi
    platform_h17_state_from "$mode" "${hex:-}"
}

# Secure Boot state: enabled | disabled | unknown
# Optional path argument, or SECURE_BOOT_FILE. A text fixture may contain
# those words. EFI variables are binary (NUL in the attribute dword) —
# never slurp them through command substitution.
platform_secure_boot_state() {
    local f="${1:-${SECURE_BOOT_FILE:-}}"
    local token v
    if [ -z "$f" ]; then
        f="/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
    fi
    [ -r "$f" ] || { printf 'unknown\n'; return 0; }
    token="$(LC_ALL=C grep -a -m1 -xE 'enabled|disabled|unknown' "$f" 2>/dev/null || true)"
    case "$token" in
        enabled|disabled|unknown)
            printf '%s\n' "$token"
            return 0
            ;;
    esac
    # EFI: UINT32 attributes at offset 0, UINT8 SecureBoot (0/1) at offset 4.
    v="$(od -An -t u1 -j 4 -N 1 "$f" 2>/dev/null | awk '{print $1}')"
    case "$v" in
        1) printf 'enabled\n' ;;
        0) printf 'disabled\n' ;;
        *) printf 'unknown\n' ;;
    esac
}

# Milestone B H17 readiness from lockdown + live classifier + loaded module.
# Prints STOCK_DRIVER_PENDING_A13 | PATCHED_DRIVER_H17_PASS | PATCHED_DRIVER_H17_FAIL
# Args: lockdown_mode h17_state loaded_version expected_patched_version
platform_h17_deployment_state() {
    local lockdown="$1"
    local h17="$2"
    local loaded="$3"
    local patched="$4"
    : "$lockdown"
    if [ "$h17" = "PASS" ]; then
        printf 'PATCHED_DRIVER_H17_PASS\n'
        return 0
    fi
    if [ -n "$patched" ] && [ "$loaded" = "$patched" ]; then
        printf 'PATCHED_DRIVER_H17_FAIL\n'
        return 0
    fi
    printf 'STOCK_DRIVER_PENDING_A13\n'
}
