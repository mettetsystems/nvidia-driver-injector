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

r610_akmods_root() {
    printf '%s\n' "${R610_AKMODS_ROOT:-/etc/pki/akmods}"
}

# fedora_<id> from a fedora_*.priv / fedora_*.der path. Empty otherwise.
r610_fedora_mok_stem() {
    local base
    base="$(basename -- "${1:-}")"
    case "$base" in
        fedora_*.priv) printf '%s\n' "${base%.priv}" ;;
        fedora_*.der)  printf '%s\n' "${base%.der}" ;;
    esac
}

# Candidate private-key paths. First readable match wins.
# Prefer matching fedora_<id>.priv over generic akmods/DKMS/shim names.
# Do not cat these files.
r610_mok_key_candidates() {
    if [ -n "${R610_MOK_KEY:-}" ]; then
        printf '%s\n' "$R610_MOK_KEY"
        return 0
    fi
    local root g
    root="$(r610_akmods_root)"
    for g in "$root/private"/fedora_*.priv; do
        [ -e "$g" ] || continue
        printf '%s\n' "$g"
    done
    printf '%s\n' \
        "$root/private/private_key.der" \
        /var/lib/dkms/mok.key \
        /var/lib/shim-signed/mok/MOK.priv
    for g in "$root/private"/*.priv "$root/private"/*.der; do
        [ -e "$g" ] || continue
        case "$g" in
            */fedora_*.priv) continue ;;
        esac
        printf '%s\n' "$g"
    done
}

r610_mok_cert_candidates() {
    if [ -n "${R610_MOK_CERT:-}" ]; then
        printf '%s\n' "$R610_MOK_CERT"
        return 0
    fi
    local root g key id paired
    root="$(r610_akmods_root)"
    key="$(r610_mok_key_path 2>/dev/null || true)"
    id="$(r610_fedora_mok_stem "$key")"
    if [ -n "$id" ]; then
        paired="$root/certs/${id}.der"
        printf '%s\n' "$paired"
    fi
    for g in "$root/certs"/fedora_*.der; do
        [ -e "$g" ] || continue
        printf '%s\n' "$g"
    done
    printf '%s\n' \
        "$root/certs/public_key.der" \
        /var/lib/dkms/mok.pub \
        /var/lib/shim-signed/mok/MOK.der
    for g in "$root/certs"/*.der "$root/certs"/*.pem; do
        [ -e "$g" ] || continue
        case "$g" in
            */fedora_*.der) continue ;;
        esac
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

# True if a candidate exists but is not readable, or its parent dir is
# present and not listable (typical akmods 750 root:akmods as non-root).
r610_any_candidate_unreadable() {
    local p d
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if [ -e "$p" ] && [ ! -r "$p" ]; then
            return 0
        fi
        d="$(dirname -- "$p")"
        if [ -d "$d" ] && [ ! -r "$d" ]; then
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

# available | unreadable | unavailable
r610_mok_key_state() {
    if r610_mok_key_path >/dev/null 2>&1; then
        printf 'available\n'
        return 0
    fi
    if r610_mok_key_candidates | r610_any_candidate_unreadable; then
        printf 'unreadable\n'
        return 0
    fi
    printf 'unavailable\n'
}

r610_mok_cert_state() {
    if r610_mok_cert_path >/dev/null 2>&1; then
        printf 'available\n'
        return 0
    fi
    if r610_mok_cert_candidates | r610_any_candidate_unreadable; then
        printf 'unreadable\n'
        return 0
    fi
    printf 'unavailable\n'
}

r610_normalize_fingerprint() {
    local s="$1"
    s="$(printf '%s' "$s" | tr 'A-F' 'a-f')"
    case "$s" in
        *fingerprint*) s="${s##*fingerprint}" ;;
        *sha1[=:]*)    s="${s##*sha1}" ;;
    esac
    printf '%s' "$s" | tr -d ' :=\n\t-'
}

r610_sha256_file() {
    sha256sum -- "$1" 2>/dev/null | awk '{print $1}'
}

# SHA256 of the certificate's DER bytes. PEM is converted; existing DER is
# hashed as-is so it matches mokutil --export output. Never dumps the body.
r610_cert_der_sha256() {
    local cert="$1"
    local openssl_bin="${OPENSSL:-openssl}"
    local tmp der
    [ -r "$cert" ] || return 1
    if "$openssl_bin" x509 -inform DER -in "$cert" -noout >/dev/null 2>&1; then
        r610_sha256_file "$cert"
        return 0
    fi
    tmp="$(mktemp -d)" || return 1
    chmod 700 "$tmp"
    der="$tmp/cert.der"
    if ! "$openssl_bin" x509 -in "$cert" -outform DER -out "$der" 2>/dev/null; then
        rm -rf "$tmp"
        return 1
    fi
    r610_sha256_file "$der"
    rm -rf "$tmp"
}

# SHA1 hex (no colons) of a PEM or DER certificate. Prefer DER (akmods).
# Never dumps the cert body. Used only for --list-enrolled SHA1 fallback.
r610_cert_sha1() {
    local cert="$1"
    local fp=""
    local openssl_bin="${OPENSSL:-openssl}"
    [ -r "$cert" ] || return 1
    fp="$("$openssl_bin" x509 -inform DER -noout -fingerprint -sha1 -in "$cert" 2>/dev/null || true)"
    if [ -z "$fp" ]; then
        fp="$("$openssl_bin" x509 -noout -fingerprint -sha1 -in "$cert" 2>/dev/null || true)"
    fi
    [ -n "$fp" ] || return 1
    r610_normalize_fingerprint "$fp"
    printf '\n'
}

r610_mokutil_bin() {
    printf '%s\n' "${MOKUTIL:-mokutil}"
}

r610_mokutil_supports_flag() {
    local bin="${1:-$(r610_mokutil_bin)}"
    local flag="$2"
    "$bin" --help 2>&1 | grep -q -- "$flag"
}

# Diagnostic only. Fedora mokutil may print "already enrolled" and still
# return rc=1; never use this exit status for PASS/FAIL.
r610_mokutil_supports_test_key() {
    r610_mokutil_supports_flag "${1:-$(r610_mokutil_bin)}" "--test-key"
}

r610_mokutil_supports_export() {
    r610_mokutil_supports_flag "${1:-$(r610_mokutil_bin)}" "--export"
}

# Print PASS or FAIL; return 0 if export produced a determination.
# Return 1 if --export is missing or failed (caller may SHA1-fallback).
# Never uses --test-key. Does not clobber the caller's EXIT trap.
r610_enrolled_state_via_export() {
    local cert="$1"
    local bin="$2"
    local tmp want h f
    r610_mokutil_supports_export "$bin" || return 1
    want="$(r610_cert_der_sha256 "$cert")" || return 1
    [ -n "$want" ] || return 1
    tmp="$(mktemp -d)" || return 1
    chmod 700 "$tmp"
    if ! ( cd "$tmp" && "$bin" --export >/dev/null 2>&1 ); then
        rm -rf "$tmp"
        return 1
    fi
    for f in "$tmp"/*.der; do
        [ -f "$f" ] || continue
        h="$(r610_sha256_file "$f")" || continue
        if [ "$h" = "$want" ]; then
            rm -rf "$tmp"
            printf 'PASS\n'
            return 0
        fi
    done
    rm -rf "$tmp"
    printf 'FAIL\n'
    return 0
}

# SHA1 vs SHA1 only. 40-hex fingerprints; never compare SHA256 to SHA1.
# Print PASS or FAIL; return 1 if the list cannot be queried/parsed.
r610_enrolled_state_via_sha1_list() {
    local cert="$1"
    local bin="$2"
    local want got line saw=0
    r610_mokutil_supports_flag "$bin" "--list-enrolled" || return 1
    want="$(r610_cert_sha1 "$cert")" || return 1
    [ "${#want}" -eq 40 ] || return 1
    while IFS= read -r line; do
        case "$line" in
            *SHA1*Fingerprint*)
                got="$(r610_normalize_fingerprint "$line")"
                [ "${#got}" -eq 40 ] || continue
                saw=1
                if [ "$got" = "$want" ]; then
                    printf 'PASS\n'
                    return 0
                fi
                ;;
        esac
    done < <("$bin" --list-enrolled 2>/dev/null || true)
    if [ "$saw" -eq 1 ]; then
        printf 'FAIL\n'
        return 0
    fi
    return 1
}

# PASS | FAIL | UNKNOWN — is this certificate in the enrolled MOK list?
# Primary: SHA256 of local DER vs each mokutil --export DER (exact match).
# Fallback: SHA1 fingerprint vs mokutil --list-enrolled SHA1 fingerprints.
# UNKNOWN if the cert is missing/unreadable or enrollment cannot be queried.
# mokutil --test-key is never authoritative (Fedora may rc=1 while enrolled).
# Do not decide enrollment by CN/name/filename/serial. Never sudo.
r610_cert_enrolled_state() {
    local cert="${1:-}"
    local mokutil_bin state
    if [ -z "$cert" ]; then
        cert="$(r610_mok_cert_path 2>/dev/null || true)"
    fi
    if [ -z "$cert" ] || [ ! -r "$cert" ]; then
        printf 'UNKNOWN\n'
        return 0
    fi
    mokutil_bin="$(r610_mokutil_bin)"
    if ! command -v "$mokutil_bin" >/dev/null 2>&1 && [ ! -x "$mokutil_bin" ]; then
        printf 'UNKNOWN\n'
        return 0
    fi
    if state="$(r610_enrolled_state_via_export "$cert" "$mokutil_bin")"; then
        printf '%s\n' "$state"
        return 0
    fi
    if state="$(r610_enrolled_state_via_sha1_list "$cert" "$mokutil_bin")"; then
        printf '%s\n' "$state"
        return 0
    fi
    printf 'UNKNOWN\n'
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
