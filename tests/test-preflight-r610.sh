#!/usr/bin/env bash
# Preflight logging + H17 Milestone B state machine. No GPU, no insmod.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
. "$here/../tools/lib/platform.sh"
. "$here/../tools/lib/nvidia-version.sh"

root="$(cd "$here/.." && pwd)"
pf="$root/scripts/preflight-r610.sh"
helper="$root/scripts/host-files/usr/local/sbin/nvidia-driver-injector-bridge-link-cap"
a13="$root/patches/addon/A13-h17-bridge-cap.patch"

assert_exit 0 "preflight-r610.sh parses (bash -n)" bash -n "$pf"

# --- 1. info() exists and does not increment counters ---
assert_file_contains "$pf" 'info() { printf' "info() helper is defined"
info_line="$(grep -E '^info\(\)' "$pf")"
assert_contains "$info_line" '[INFO]' "info() prints [INFO]"
if printf '%s' "$info_line" | grep -qE 'ok=\$\(\(ok|warn=\$\(\(warn|fail=\$\(\(fail'; then
    assert_eq "increments counters" "no increment" "info() must not increment OK/WARN/FAIL"
else
    assert_eq "1" "1" "info() must not increment OK/WARN/FAIL"
fi

# Defined logging helpers vs call sites. Catches the original info "..." abort.
defined=" ok warn fail info "
undef=""
while IFS= read -r fn; do
    [ -n "$fn" ] || continue
    case " $defined " in
        *" $fn "*) ;;
        *) undef="${undef}${undef:+ }$fn" ;;
    esac
done < <(grep -E '^[[:space:]]+(ok|warn|fail|info|error|err|log|note|debug|notice|msg|die)[[:space:]]+"' "$pf" \
    | sed -E 's/^[[:space:]]+([A-Za-z_]+).*/\1/' | sort -u)
assert_eq "$undef" "" "no undefined logging helpers called"

# --- 2–4. H17 deployment state machine ---
patched="610.57.04-apnex.1"
assert_eq "$(platform_h17_deployment_state integrity WRITE_BLOCKED 610.57.04 "$patched")" \
    "STOCK_DRIVER_PENDING_A13" \
    "stock + lockdown + H17!=PASS => PENDING_A13"
assert_eq "$(platform_h17_deployment_state integrity WRITE_BLOCKED '(not loaded)' "$patched")" \
    "STOCK_DRIVER_PENDING_A13" \
    "unloaded module + lockdown => PENDING_A13"
assert_eq "$(platform_h17_deployment_state integrity PASS "$patched" "$patched")" \
    "PATCHED_DRIVER_H17_PASS" \
    "patched + H17 PASS => PASS"
assert_eq "$(platform_h17_deployment_state integrity WRITE_BLOCKED "$patched" "$patched")" \
    "PATCHED_DRIVER_H17_FAIL" \
    "patched + H17 WRITE_BLOCKED => FAIL CLOSED"
assert_eq "$(platform_h17_deployment_state integrity VERIFY_FAILED "$patched" "$patched")" \
    "PATCHED_DRIVER_H17_FAIL" \
    "patched + H17 VERIFY_FAILED => FAIL CLOSED"

# A13 is present in the repo (precondition for PENDING being valid).
assert_file_contains "$a13" 'PCI_EXP_LNKCTL2_HASD' "A13 kernel H17 patch present"

# Preflight must INFO (not FAIL) on stock pending; FAIL only when patched is live.
stock_body="$(awk '/STOCK_DRIVER_PENDING_A13)/,/PATCHED_DRIVER_H17_PASS)/' "$pf")"
if printf '%s' "$stock_body" | grep -qE '^[[:space:]]+fail '; then
    assert_eq "fail in PENDING branch" "info only" "stock PENDING_A13 must not fail preflight"
else
    assert_eq "1" "1" "stock PENDING_A13 must not fail preflight"
fi
assert_contains "$stock_body" "PASS for Milestone B" "PENDING readiness is PASS for Milestone B"
assert_contains "$stock_body" "PENDING_A13" "PENDING displays live H17=PENDING_A13"

fail_body="$(awk '/PATCHED_DRIVER_H17_FAIL)/,/^esac/' "$pf")"
assert_contains "$fail_body" 'fail "' "patched H17 failure fail-closes preflight"

# Old blanket fail under lockdown must stay gone.
if grep -q 'userspace cap is blocked; load patched nvidia.ko' "$pf"; then
    assert_eq "old lockdown fail" "removed" "must not fail preflight solely because lockdown blocks setpci"
else
    assert_eq "1" "1" "must not fail preflight solely because lockdown blocks setpci"
fi

# Table labels
assert_file_contains "$pf" 'Secure Boot' "reports Secure Boot"
assert_file_contains "$pf" 'kernel lockdown' "reports kernel lockdown"
assert_file_contains "$pf" 'blocked by lockdown' "reports userspace H17 blocked by lockdown"
assert_file_contains "$pf" 'A13 kernel H17' "reports A13 kernel H17"
assert_file_contains "$pf" 'loaded module' "reports loaded module"
assert_file_contains "$pf" 'live H17' "reports live H17"
assert_file_contains "$pf" 'readiness' "reports readiness"

# --- 5. Lockdown must never cause fallback to disabling Secure Boot ---
sb_bad=""
while IFS= read -r line; do
    [ -n "$line" ] || continue
    if printf '%s' "$line" | grep -qiE 'do not|don'\''t|never'; then
        continue
    fi
    sb_bad="${sb_bad}${sb_bad:+; }$line"
done < <(grep -nEi 'disable (secure boot|lockdown)|turn off (secure boot|lockdown)' "$pf" "$helper" || true)
assert_eq "$sb_bad" "" "lockdown never recommends disabling Secure Boot"

# --- 6. Userspace setpci failure remains fail-closed ---
assert_file_contains "$helper" 'H17_WRITE_BLOCKED=3' "helper WRITE_BLOCKED exit 3"
assert_file_contains "$helper" 'h17_classify_write_err' "helper classifies EPERM as WRITE_BLOCKED"
assert_file_contains "$helper" 'return "$rc"' "write_word returns setpci status"
assert_file_contains "$pf" 'H17_WRITE_BLOCKED' "preflight requires fail-closed helper"

finish_tests
