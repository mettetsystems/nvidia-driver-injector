# Host-side NVIDIA module signing helpers. Source from repo-relative tools.
# Never prints, copies, or logs private-key material.

r610_required_ko_names() {
    printf '%s\n' nvidia.ko nvidia-modeset.ko nvidia-drm.ko nvidia-uvm.ko
}

r610_optional_ko_names() {
    printf '%s\n' nvidia-peermem.ko
}

r610_all_ko_names() {
    r610_required_ko_names
    r610_optional_ko_names
}

r610_kver() {
    printf '%s\n' "${R610_KVER:-$(uname -r)}"
}

# Staging lives next to (not inside) extra/, so unsigned .ko never enter depmod.
r610_staging_root() {
    printf '%s\n' "${R610_STAGING_ROOT:-/lib/modules/$(r610_kver)/nvidia-driver-injector}"
}

r610_staging_unsigned() {
    printf '%s\n' "$(r610_staging_root)/unsigned"
}

r610_staging_signed() {
    printf '%s\n' "$(r610_staging_root)/signed"
}

r610_sign_hash_algo() {
    if [ -n "${R610_SIGN_HASH:-}" ]; then
        printf '%s\n' "$R610_SIGN_HASH"
        return 0
    fi
    local cfg="${R610_KERNEL_CONFIG:-/boot/config-$(r610_kver)}"
    local line=""
    [ -r "$cfg" ] || cfg="/lib/modules/$(r610_kver)/build/.config"
    if [ -r "$cfg" ]; then
        line="$(grep -E '^CONFIG_MODULE_SIG_HASH=' "$cfg" 2>/dev/null || true)"
        line="${line#CONFIG_MODULE_SIG_HASH=}"
        line="${line#\"}"
        line="${line%\"}"
    fi
    printf '%s\n' "${line:-sha512}"
}

r610_sign_file_path() {
    printf '%s\n' "${R610_SIGN_FILE:-/usr/src/kernels/$(r610_kver)/scripts/sign-file}"
}

# Candidate private-key paths. First readable match wins.
# Do not cat these files.
r610_mok_key_candidates() {
    if [ -n "${R610_MOK_KEY:-}" ]; then
        printf '%s\n' "$R610_MOK_KEY"
        return 0
    fi
    printf '%s\n' \
        /etc/pki/akmods/private/private_key.der \
        /var/lib/dkms/mok.key \
        /var/lib/shim-signed/mok/MOK.priv
    local g
    for g in /etc/pki/akmods/private/*.priv /etc/pki/akmods/private/*.der; do
        [ -e "$g" ] || continue
        printf '%s\n' "$g"
    done
}

r610_mok_cert_candidates() {
    if [ -n "${R610_MOK_CERT:-}" ]; then
        printf '%s\n' "$R610_MOK_CERT"
        return 0
    fi
    printf '%s\n' \
        /etc/pki/akmods/certs/public_key.der \
        /var/lib/dkms/mok.pub \
        /var/lib/shim-signed/mok/MOK.der
    local g
    for g in /etc/pki/akmods/certs/*.der /etc/pki/akmods/certs/*.pem; do
        [ -e "$g" ] || continue
        printf '%s\n' "$g"
    done
}

r610_first_readable() {
    local p
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if [ -r "$p" ]; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    return 1
}

r610_mok_key_path() {
    r610_mok_key_candidates | r610_first_readable
}

r610_mok_cert_path() {
    r610_mok_cert_candidates | r610_first_readable
}

# available | unavailable
r610_mok_key_state() {
    if r610_mok_key_path >/dev/null 2>&1; then
        printf 'available\n'
    else
        printf 'unavailable\n'
    fi
}

r610_mok_cert_state() {
    if r610_mok_cert_path >/dev/null 2>&1; then
        printf 'available\n'
    else
        printf 'unavailable\n'
    fi
}

r610_normalize_fingerprint() {
    local s="$1"
    s="${s#SHA1 Fingerprint}"
    s="${s#[:= ]}"
    s="${s# }"
    printf '%s' "$s" | tr 'A-F' 'a-f' | tr -d ' :\n\t'
}

# SHA1 hex (no colons) of a PEM or DER certificate. Never dumps the cert body.
r610_cert_sha1() {
    local cert="$1"
    local fp=""
    local openssl_bin="${OPENSSL:-openssl}"
    [ -r "$cert" ] || return 1
    fp="$("$openssl_bin" x509 -noout -fingerprint -sha1 -in "$cert" 2>/dev/null || true)"
    if [ -z "$fp" ]; then
        fp="$("$openssl_bin" x509 -inform DER -noout -fingerprint -sha1 -in "$cert" 2>/dev/null || true)"
    fi
    [ -n "$fp" ] || return 1
    r610_normalize_fingerprint "$fp"
    printf '\n'
}

r610_mokutil_bin() {
    printf '%s\n' "${MOKUTIL:-mokutil}"
}

# PASS | FAIL — is this certificate in the enrolled MOK list?
# Primary: mokutil --test-key "$cert" EXIT STATUS (never parse English).
# Fallback: SHA1 fingerprint vs --list-enrolled, only if --test-key is absent.
# Do not decide enrollment by CN/name matching. Never sudo (caller may already be root).
r610_mokutil_supports_test_key() {
    local bin="${1:-$(r610_mokutil_bin)}"
    "$bin" --help 2>&1 | grep -q -- '--test-key'
}

r610_cert_enrolled_state() {
    local cert="${1:-}"
    local mokutil_bin want got line
    if [ -z "$cert" ]; then
        cert="$(r610_mok_cert_path 2>/dev/null || true)"
    fi
    if [ -z "$cert" ] || [ ! -r "$cert" ]; then
        printf 'FAIL\n'
        return 0
    fi
    mokutil_bin="$(r610_mokutil_bin)"
    if ! command -v "$mokutil_bin" >/dev/null 2>&1 && [ ! -x "$mokutil_bin" ]; then
        printf 'FAIL\n'
        return 0
    fi
    if r610_mokutil_supports_test_key "$mokutil_bin"; then
        if "$mokutil_bin" --test-key "$cert" >/dev/null 2>&1; then
            printf 'PASS\n'
        else
            printf 'FAIL\n'
        fi
        return 0
    fi
    want="$(r610_cert_sha1 "$cert" 2>/dev/null || true)"
    if [ -z "$want" ]; then
        printf 'FAIL\n'
        return 0
    fi
    while IFS= read -r line; do
        case "$line" in
            *SHA1*Fingerprint*)
                got="$(r610_normalize_fingerprint "$line")"
                if [ "$got" = "$want" ]; then
                    printf 'PASS\n'
                    return 0
                fi
                ;;
        esac
    done < <("$mokutil_bin" --list-enrolled 2>/dev/null || true)
    printf 'FAIL\n'
}

# CN from the signing certificate (PEM or DER). unknown if unreadable.
r610_cert_identity() {
    local cert="${1:-}"
    local subj="" cn=""
    local openssl_bin="${OPENSSL:-openssl}"
    if [ -z "$cert" ]; then
        cert="$(r610_mok_cert_path 2>/dev/null || true)"
    fi
    if [ -z "$cert" ] || [ ! -r "$cert" ]; then
        printf 'unknown\n'
        return 0
    fi
    subj="$("$openssl_bin" x509 -noout -subject -nameopt RFC2253,-esc_msb -in "$cert" 2>/dev/null || true)"
    if [ -z "$subj" ]; then
        subj="$("$openssl_bin" x509 -inform DER -noout -subject -nameopt RFC2253,-esc_msb -in "$cert" 2>/dev/null || true)"
    fi
    cn="${subj#*CN=}"
    cn="${cn%%,*}"
    if [ -z "$cn" ] || [ "$cn" = "$subj" ]; then
        printf 'unknown\n'
        return 0
    fi
    printf '%s\n' "$cn"
}

r610_modinfo_bin() {
    printf '%s\n' "${MODINFO:-modinfo}"
}

r610_module_field() {
    local ko="$1" field="$2"
    local bin
    bin="$(r610_modinfo_bin)"
    "$bin" -F "$field" "$ko" 2>/dev/null || true
}

r610_module_signer() {
    r610_module_field "$1" signer
}

r610_module_version() {
    r610_module_field "$1" version
}

r610_module_has_signature() {
    local signer
    signer="$(r610_module_signer "$1")"
    [ -n "$signer" ]
}

# yes | no — required .ko present in dir (optional peermem ignored).
r610_modules_built_state() {
    local dir="${1:-$(r610_staging_unsigned)}"
    local name
    [ -d "$dir" ] || { printf 'no\n'; return 0; }
    while IFS= read -r name; do
        if [ ! -f "$dir/$name" ]; then
            printf 'no\n'
            return 0
        fi
    done < <(r610_required_ko_names)
    printf 'yes\n'
}

# PASS (all required+present optional signed, versions match patched)
# PENDING (not built, or unsigned while not a mix)
# FAIL (partial signatures, version mix, or verify mismatch)
r610_modules_signed_state() {
    local dir="${1:-$(r610_staging_signed)}"
    local expected="${2:-}"
    local name ko signed=0 unsigned=0 present=0 ver
    if [ "$(r610_modules_built_state "$dir")" != "yes" ]; then
        printf 'PENDING\n'
        return 0
    fi
    while IFS= read -r name; do
        ko="$dir/$name"
        [ -f "$ko" ] || continue
        present=$((present + 1))
        if [ -n "$expected" ]; then
            ver="$(r610_module_version "$ko")"
            if [ -n "$ver" ] && [ "$ver" != "$expected" ]; then
                printf 'FAIL\n'
                return 0
            fi
        fi
        if r610_module_has_signature "$ko"; then
            signed=$((signed + 1))
        else
            unsigned=$((unsigned + 1))
        fi
    done < <(r610_all_ko_names)
    if [ "$unsigned" -gt 0 ] && [ "$signed" -gt 0 ]; then
        printf 'FAIL\n'
        return 0
    fi
    if [ "$unsigned" -gt 0 ] || [ "$signed" -eq 0 ]; then
        printf 'PENDING\n'
        return 0
    fi
    printf 'PASS\n'
}

# Verify one module: has signer, and if cert given, signer is present (non-empty).
# Enrollment is checked separately against the cert, not per-module CN.
r610_verify_one_module() {
    local ko="$1"
    local expected="${2:-}"
    local ver
    [ -f "$ko" ] || return 1
    r610_module_has_signature "$ko" || return 1
    if [ -n "$expected" ]; then
        ver="$(r610_module_version "$ko")"
        [ -z "$ver" ] || [ "$ver" = "$expected" ] || return 1
    fi
    return 0
}

# Exit 0 only if the directory is a complete signed set.
r610_verify_module_dir() {
    local dir="$1"
    local expected="${2:-}"
    local sb="${3:-}"
    local name ko
    [ -d "$dir" ] || return 1
    while IFS= read -r name; do
        ko="$dir/$name"
        if [ ! -f "$ko" ]; then
            return 1
        fi
        if ! r610_verify_one_module "$ko" "$expected"; then
            return 1
        fi
    done < <(r610_required_ko_names)
    while IFS= read -r name; do
        ko="$dir/$name"
        [ -f "$ko" ] || continue
        if ! r610_verify_one_module "$ko" "$expected"; then
            return 1
        fi
    done < <(r610_optional_ko_names)
    if [ "$sb" = "enabled" ]; then
        [ "$(r610_cert_enrolled_state)" = "PASS" ] || return 1
    fi
    return 0
}

# Fail closed when Secure Boot is enabled and the set is not fully verified.
r610_sign_gate() {
    local dir="${1:-$(r610_staging_signed)}"
    local expected="${2:-}"
    local sb
    sb="$(platform_secure_boot_state 2>/dev/null || echo unknown)"
    if [ "$sb" != "enabled" ]; then
        return 0
    fi
    r610_verify_module_dir "$dir" "$expected" "$sb"
}

r610_milestone_b_sign_readiness() {
    local sb="$1"
    local key_state="$2"
    local cert_state="$3"
    local enrolled="$4"
    local built="$5"
    local signed="$6"
    if [ "$signed" = "FAIL" ]; then
        printf 'FAIL\n'
        return 0
    fi
    if [ "$sb" != "enabled" ]; then
        printf 'PASS\n'
        return 0
    fi
    if [ "$key_state" = "available" ] && [ "$cert_state" = "available" ] \
        && [ "$enrolled" = "PASS" ] && [ "$built" = "yes" ] && [ "$signed" = "PASS" ]; then
        printf 'PASS\n'
        return 0
    fi
    printf 'FAIL\n'
}

# Copy produced .ko into dest. Never overwrites extra/nvidia/ (stock rollback).
r610_export_modules() {
    local src="$1"
    local dest="$2"
    local name
    mkdir -p "$dest"
    while IFS= read -r name; do
        if [ -f "$src/$name" ]; then
            cp -f "$src/$name" "$dest/$name"
        fi
    done < <(r610_all_ko_names)
}

# Sign one module. Key path is passed to sign-file only; never echoed.
r610_sign_one_module() {
    local ko="$1"
    local dest="${2:-}"
    local key cert hash sf
    key="$(r610_mok_key_path)" || return 1
    cert="$(r610_mok_cert_path)" || return 1
    hash="$(r610_sign_hash_algo)"
    sf="$(r610_sign_file_path)"
    [ -x "$sf" ] || return 1
    [ -f "$ko" ] || return 1
    set +x
    if [ -n "$dest" ] && [ "$dest" != "$ko" ]; then
        mkdir -p "$(dirname "$dest")"
        cp -f "$ko" "$dest"
        "$sf" "$hash" "$key" "$cert" "$dest" || return 1
    else
        "$sf" "$hash" "$key" "$cert" "$ko" || return 1
    fi
}

r610_sign_module_dir() {
    local src="$1"
    local dest="${2:-$src}"
    local name ko
    mkdir -p "$dest"
    while IFS= read -r name; do
        ko="$src/$name"
        [ -f "$ko" ] || continue
        if [ "$dest" = "$src" ]; then
            r610_sign_one_module "$ko" || return 1
        else
            r610_sign_one_module "$ko" "$dest/$name" || return 1
        fi
    done < <(r610_all_ko_names)
}

# Print signer of a loaded module name (nvidia, nvidia_modeset, ...).
r610_loaded_module_signer() {
    local short="$1"
    local proc="${PROC_MODULES:-/proc/modules}"
    grep -E "^${short} " "$proc" >/dev/null 2>&1 || return 1
    r610_module_field "$short" signer
}

r610_loaded_module_version_of() {
    local short="$1"
    local proc="${PROC_MODULES:-/proc/modules}"
    grep -E "^${short} " "$proc" >/dev/null 2>&1 || return 1
    r610_module_field "$short" version
}
