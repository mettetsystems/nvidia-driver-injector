#!/usr/bin/env bash
# verify-r610-signatures.sh — fail-closed signature + enrollment check.
#
# Never loads or unloads modules. Never prints private-key material.
#
#   ./scripts/verify-r610-signatures.sh --dir DIR
#   ./scripts/verify-r610-signatures.sh --loaded
#
# --dir    verify a staged signed set (default: staging/signed)
# --loaded verify the actually loaded nvidia* modules (status path)
#
# Under Secure Boot=enabled: unsigned, partially signed, untrusted, or
# unenrolled signer → exit 1.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../tools/lib/platform.sh
. "$REPO_ROOT/tools/lib/platform.sh"
# shellcheck source=../tools/lib/nvidia-version.sh
. "$REPO_ROOT/tools/lib/nvidia-version.sh"
# shellcheck source=../tools/lib/module-sign.sh
. "$REPO_ROOT/tools/lib/module-sign.sh"

DIR=""
LOADED=0

usage() {
    sed -n '/^# verify-r610/,/^set -euo/p' "$0" | sed 's/^# \?//' | head -n -1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir) DIR="${2:-}"; shift 2 ;;
        --loaded) LOADED=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

nvidia_version_load "$REPO_ROOT"
expected="$(nvidia_composed_module_version "$REPO_ROOT")"
sb="$(platform_secure_boot_state)"
enrolled="$(r610_cert_enrolled_state)"
key_state="$(r610_mok_key_state)"
cert_state="$(r610_mok_cert_state)"
rc=0

echo "== verify-r610-signatures =="
echo "  Secure Boot=$sb"
echo "  signing private key=$key_state"
echo "  signing certificate=$cert_state"
echo "  certificate enrolled=$enrolled"
echo "  expected patched version=$expected"

verify_loaded() {
    local short ko_name ver signer any=0 patched=0
    echo "  loaded modules:"
    for short in nvidia nvidia_modeset nvidia_drm nvidia_uvm nvidia_peermem; do
        ver="$(r610_loaded_module_version_of "$short" 2>/dev/null || true)"
        [[ -n "$ver" ]] || continue
        any=1
        signer="$(r610_loaded_module_signer "$short" 2>/dev/null || true)"
        if [[ -z "$signer" ]]; then
            echo "    $short version=$ver signer=(none) UNSIGNED"
            if [[ "$sb" == "enabled" ]]; then
                rc=1
            fi
        else
            echo "    $short version=$ver signer=$signer"
        fi
        if [[ "$ver" == "$expected" ]]; then
            patched=1
            if [[ -z "$signer" ]]; then
                rc=1
            fi
        elif [[ "$ver" != "$NVIDIA_OPEN_TAG" ]]; then
            echo "    MIXED version $ver (neither stock $NVIDIA_OPEN_TAG nor $expected)"
            rc=1
        fi
    done
    if [[ "$any" -eq 0 ]]; then
        echo "    (none loaded)"
        return 0
    fi
    if [[ "$patched" -eq 1 && "$sb" == "enabled" && "$enrolled" != "PASS" ]]; then
        if [[ "$enrolled" == "FAIL" ]]; then
            echo "  FAIL: patched module loaded but signing certificate is not enrolled"
        else
            echo "  FAIL: patched module loaded but MOK enrollment could not be confirmed"
        fi
        rc=1
    fi
    if [[ "$patched" -eq 0 ]]; then
        echo "  loaded set is stock $NVIDIA_OPEN_TAG (rollback path)"
    fi
}

verify_dir() {
    local dir="$1"
    local name ko signer ver signed=0 unsigned=0
    echo "  dir=$dir"
    if [[ ! -d "$dir" ]]; then
        echo "  FAIL: directory missing"
        rc=1
        return 0
    fi
    while IFS= read -r name; do
        ko="$dir/$name"
        if [[ ! -f "$ko" ]]; then
            echo "    $name MISSING"
            rc=1
            continue
        fi
        ver="$(r610_module_version "$ko")"
        signer="$(r610_module_signer "$ko")"
        if [[ -z "$signer" ]]; then
            echo "    $name version=${ver:-unknown} UNSIGNED"
            unsigned=$((unsigned + 1))
        else
            echo "    $name version=${ver:-unknown} signer=$signer"
            signed=$((signed + 1))
        fi
        if [[ -n "$ver" && "$ver" != "$expected" ]]; then
            echo "    FAIL: $name version $ver != $expected (refusing stock/patched mix)"
            rc=1
        fi
    done < <(r610_required_ko_names)
    while IFS= read -r name; do
        ko="$dir/$name"
        [[ -f "$ko" ]] || continue
        ver="$(r610_module_version "$ko")"
        signer="$(r610_module_signer "$ko")"
        if [[ -z "$signer" ]]; then
            echo "    $name version=${ver:-unknown} UNSIGNED (present, so required)"
            unsigned=$((unsigned + 1))
        else
            echo "    $name version=${ver:-unknown} signer=$signer"
            signed=$((signed + 1))
        fi
        if [[ -n "$ver" && "$ver" != "$expected" ]]; then
            echo "    FAIL: $name version mix"
            rc=1
        fi
    done < <(r610_optional_ko_names)
    if [[ "$unsigned" -gt 0 && "$signed" -gt 0 ]]; then
        echo "  FAIL: partially signed module set"
        rc=1
    fi
    if [[ "$sb" == "enabled" ]]; then
        if [[ "$unsigned" -gt 0 || "$signed" -eq 0 ]]; then
            echo "  FAIL: Secure Boot enabled and module set is not fully signed"
            rc=1
        fi
        if [[ "$enrolled" != "PASS" ]]; then
            if [[ "$enrolled" == "FAIL" ]]; then
                echo "  FAIL: certificate not enrolled (do not disable Secure Boot; enroll MOK instead)"
            else
                echo "  FAIL: cannot confirm MOK enrollment (readable cert required; do not import a new MOK unless mokutil --test-key fails as root)"
            fi
            rc=1
        fi
    else
        if [[ "$unsigned" -gt 0 ]]; then
            echo "  INFO: unsigned modules allowed because Secure Boot is $sb"
        fi
    fi
}

if [[ "$LOADED" -eq 1 ]]; then
    verify_loaded
else
    DIR="${DIR:-$(r610_staging_signed)}"
    verify_dir "$DIR"
fi

if [[ "$rc" -ne 0 ]]; then
    echo "verify-r610-signatures: FAIL"
    exit 1
fi
echo "verify-r610-signatures: PASS"
exit 0
