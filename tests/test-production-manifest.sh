#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"

root="$(cd "$here/.." && pwd)"
. "$root/tools/lib/manifest.sh"

# production manifest: 20 rows, files exist, A11 before A10, C6 first
rows="$(manifest_rows "$root/patches/manifest")"
count="$(printf '%s\n' "$rows" | grep -c .)"
assert_eq "$count" "20" "production manifest has 20 rows"

first="$(printf '%s\n' "$rows" | awk 'NR==1{print $1}')"
assert_eq "$first" "C6-cond-acquire-rwlock-fix" "C6 is first"

ids="$(printf '%s\n' "$rows" | awk '{print $1}')"
a11_n="$(printf '%s\n' "$ids" | grep -n 'A11-f45-deadlock-breaker' | cut -d: -f1)"
a10_n="$(printf '%s\n' "$ids" | grep -n 'A10-f40b-lockfree-sink' | cut -d: -f1)"
if [ "$a11_n" -lt "$a10_n" ]; then
    assert_eq "1" "1" "A11 applies before A10"
else
    assert_eq "$a11_n" "before $a10_n" "A11 applies before A10"
fi

# every row has a patch file; no duplicate ids (lint)
manifest_lint "$root/patches/manifest" 2>/dev/null
assert_eq "$?" "0" "production manifest lints"

while read -r id layer _ _; do
    [ -n "${id:-}" ] || continue
    if [ -f "$root/patches/$layer/$id.patch" ]; then
        assert_eq "1" "1" "patch file $id"
    else
        assert_eq "missing" "$id" "patch file $id"
    fi
done <<EOF
$rows
EOF

# R610 literals in ported patches
assert_file_contains "$root/patches/base/C1-kbuild-version-mk.patch" \
    '610.57.04' "C1 targets 610.57.04"
if grep -q '595.71.05' "$root/patches/base/C1-kbuild-version-mk.patch"; then
    assert_eq "has 595" "no 595" "C1 must not still minus 595.71.05"
else
    assert_eq "1" "1" "C1 must not still minus 595.71.05"
fi
assert_file_contains "$root/patches/addon/A5-version-and-toggles.patch" \
    'NVIDIA_VERSION = 610.57.04-apnex.1' "A5 stamps apnex.1"
assert_file_contains "$root/patches/base/C5-crash-safety.patch" \
    'is_cxl_dev' "C5 anchors on R610 is_cxl_dev"
assert_file_contains "$root/patches/addon/A3-recovery.patch" \
    'nv-caps-imex.h' "A3 includes after nv-caps-imex.h"
assert_file_contains "$root/patches/addon/A13-h17-bridge-cap.patch" \
    'PCI_EXP_LNKCTL2_HASD' "A13 sets LnkCtl2 HASD"
assert_file_contains "$root/patches/addon/A13-h17-bridge-cap.patch" \
    '0x2b85' "A13 is GB202-scoped"

# no RC watchdog patch in production set
if grep -R 'WATCHDOG_GPFIFO_ENTRIES' "$root/patches/base" "$root/patches/addon" >/dev/null 2>&1; then
    assert_eq "present" "absent" "no production GPFIFO watchdog patch yet"
else
    assert_eq "1" "1" "no production GPFIFO watchdog patch yet"
fi

finish_tests
