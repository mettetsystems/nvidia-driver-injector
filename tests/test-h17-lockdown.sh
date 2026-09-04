#!/usr/bin/env bash
# H17 lockdown / fail-closed userspace helper. No GPU, no insmod, no real PCI writes.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
. "$here/../tools/lib/platform.sh"

root="$(cd "$here/.." && pwd)"
helper="$root/scripts/host-files/usr/local/sbin/nvidia-driver-injector-bridge-link-cap"
a13="$root/patches/addon/A13-h17-bridge-cap.patch"

os="$(mktemp -d)"
trap 'rm -rf "$os"' EXIT

# --- lockdown parser ---
printf 'none [integrity] confidentiality\n' > "$os/ld-int"
assert_eq "$(platform_lockdown_mode "$os/ld-int")" "integrity" "parse lockdown=integrity"
printf '[none] integrity confidentiality\n' > "$os/ld-none"
assert_eq "$(platform_lockdown_mode "$os/ld-none")" "none" "parse lockdown=none"
printf 'none integrity [confidentiality]\n' > "$os/ld-conf"
assert_eq "$(platform_lockdown_mode "$os/ld-conf")" "confidentiality" "parse lockdown=confidentiality"

# --- status classifier (read-only) ---
assert_eq "$(platform_h17_state_from integrity 0041)" "WRITE_BLOCKED" \
    "lockdown+bit5=0 is WRITE_BLOCKED not PASS"
assert_eq "$(platform_h17_state_from none 0041)" "VERIFY_FAILED" \
    "no lockdown + mismatch is VERIFY_FAILED"
assert_eq "$(platform_h17_state_from integrity 0063)" "PASS" \
    "0x0063 is PASS even under lockdown (in-driver cap)"
assert_eq "$(platform_h17_state_from none 0063)" "PASS" "0x0063 is PASS"

# --- A13 patch text ---
assert_file_contains "$a13" 'tb_egpu_h17_is_gb202' "A13 skips non-GB202"
assert_file_contains "$a13" 'PCI_EXP_LNKCTL2_HASD' "A13 sets HASD"
assert_file_contains "$a13" '0x2b85' "A13 names 0x2b85"
assert_file_contains "$a13" 'pci_upstream_bridge' "A13 uses dynamic upstream bridge"
if grep -q '0x1f07' "$a13"; then
    assert_eq "mentions 2070 id" "no 2070 write path" "A13 must not target 2070 device id"
else
    assert_eq "1" "1" "A13 must not target 2070 device id"
fi

# --- mock dual-GPU sysfs: 2070 must not become BRIDGE ---
pci="$os/pci"
real="$os/real/0000:8c:00.0/0000:8d:00.0"
mkdir -p "$pci/0000:02:00.0" "$real" "$pci/0000:8c:00.0"
printf '0x10de\n' > "$pci/0000:02:00.0/vendor"
printf '0x1f07\n' > "$pci/0000:02:00.0/device"
printf '0x8086\n' > "$pci/0000:8c:00.0/vendor"
printf '0x0000\n' > "$pci/0000:8c:00.0/device"
printf '0x10de\n' > "$real/vendor"
printf '0x2b85\n' > "$real/device"
ln -sfn "$real" "$pci/0000:8d:00.0"

stub="$os/setpci"
log="$os/setpci.log"
cat > "$stub" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "${SETPCI_LOG:?}"
reg=""
bdf=""
prev=""
for a in "$@"; do
    if [[ "$prev" == "-s" ]]; then bdf="$a"; fi
    if [[ "$a" == *=* ]]; then
        echo "WRITE $bdf $a" >> "${SETPCI_LOG}"
        if [[ "${SETPCI_FAIL:-}" == "eperm" ]]; then
            echo "pcilib: sysfs_write: write failed: Operation not permitted" >&2
            exit 1
        fi
        if [[ "${SETPCI_FAIL:-}" == "other" ]]; then
            echo "setpci: Device does not exist" >&2
            exit 1
        fi
        if [[ "$a" == *0x30.W=* ]]; then
            echo "${a##*=}" > "${SETPCI_LNKCTL2:?}"
        fi
        exit 0
    fi
    reg="$a"
    prev="$a"
done
if [[ "$reg" == *0x30.W ]]; then
    if [[ "${SETPCI_STALE:-}" == "1" ]]; then
        echo 0041
    else
        cat "${SETPCI_LNKCTL2:-/dev/null}" 2>/dev/null || echo 0041
    fi
    exit 0
fi
if [[ "$reg" == *0x10.W ]]; then echo 0000; exit 0; fi
if [[ "$reg" == *0x12.W ]]; then echo 1001; exit 0; fi
echo 0000
exit 0
STUB
chmod +x "$stub"
printf '0041\n' > "$os/lnkctl2"

run_helper() {
    local ld="$1" cmd="$2"
    local -a envb=(
        LOCKDOWN_FILE="$ld"
        SETPCI="$stub"
        SETPCI_LOG="$log"
        SETPCI_LNKCTL2="$os/lnkctl2"
        PCI_SYSFS="$pci"
        FORCE_TB=1
        SETPCI_FAIL="${SETPCI_FAIL:-}"
        SETPCI_STALE="${SETPCI_STALE:-}"
    )
    if [ "${3-uset}" != "" ]; then
        envb+=(BRIDGE="${3:-0000:8c:00.0}")
    fi
    env "${envb[@]}" bash "$helper" "$cmd" 2>"$os/err" >"$os/out" || echo $?
}

: > "$log"
printf '0041\n' > "$os/lnkctl2"
code="$(SETPCI_FAIL=eperm run_helper "$os/ld-none" apply | tail -1)"
assert_eq "$code" "3" "EPERM apply exits WRITE_BLOCKED (3)"
assert_file_contains "$os/err" "H17=WRITE_BLOCKED" "EPERM prints H17=WRITE_BLOCKED"
if grep -q 'retrain triggered' "$os/out" "$os/err" 2>/dev/null; then
    assert_eq "retrain printed" "no retrain" "EPERM must not report retrain success"
else
    assert_eq "1" "1" "EPERM must not report retrain success"
fi

: > "$log"
printf '0041\n' > "$os/lnkctl2"
code="$(SETPCI_FAIL=other run_helper "$os/ld-none" apply | tail -1)"
assert_eq "$code" "4" "non-EPERM write failure exits WRITE_FAILED (4)"
assert_file_contains "$os/err" "H17=WRITE_FAILED" "WRITE_FAILED label"

: > "$log"
printf '0041\n' > "$os/lnkctl2"
code="$(SETPCI_STALE=1 run_helper "$os/ld-none" apply | tail -1)"
assert_eq "$code" "5" "stale readback exits VERIFY_FAILED (5)"
assert_file_contains "$os/err" "H17=VERIFY_FAILED" "VERIFY_FAILED label"

: > "$log"
printf '0041\n' > "$os/lnkctl2"
code="$(run_helper "$os/ld-int" apply | tail -1)"
assert_eq "$code" "3" "lockdown=integrity apply exits WRITE_BLOCKED without claiming PASS"
assert_file_contains "$os/err" "H17=WRITE_BLOCKED" "integrity apply is WRITE_BLOCKED"
if grep -q 'retrain triggered' "$os/out" "$os/err" 2>/dev/null; then
    assert_eq "retrain" "no" "lockdown apply must not report retrain success"
else
    assert_eq "1" "1" "lockdown apply must not report retrain success"
fi

: > "$log"
printf '0041\n' > "$os/lnkctl2"
unset SETPCI_FAIL SETPCI_STALE
code="$(run_helper "$os/ld-none" apply | tail -1)"
# success path: stub stores 0063 and readback uses it; exit 0 so run_helper prints nothing extra
if grep -q 'H17=PASS' "$os/out" "$os/err"; then
    assert_eq "1" "1" "successful apply prints H17=PASS"
else
    assert_eq "$(cat "$os/err"; echo exit:$code)" "H17=PASS" "successful apply prints H17=PASS"
fi

# Discovery: 2070 is not the bridge
: > "$log"
printf '0041\n' > "$os/lnkctl2"
SETPCI_FAIL=eperm run_helper "$os/ld-none" apply "" >/dev/null || true
if grep -q '02:00.0' "$log"; then
    assert_eq "wrote 2070" "no 2070" "helper must not setpci the RTX 2070"
else
    assert_eq "1" "1" "helper must not setpci the RTX 2070"
fi
if grep -q '8c:00.0' "$log"; then
    assert_eq "1" "1" "helper discovers GB202 parent bridge 8c:00.0"
else
    assert_eq "$(cat "$log")" "contains 8c:00.0" "helper discovers GB202 parent bridge"
fi

finish_tests
