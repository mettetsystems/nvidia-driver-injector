#!/usr/bin/env bash
# Secure Boot signing gate. No GPU, no insmod, no real MOK private-key logs.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
. "$here/../tools/lib/platform.sh"
. "$here/../tools/lib/nvidia-version.sh"
. "$here/../tools/lib/module-sign.sh"

root="$(cd "$here/.." && pwd)"
os="$(mktemp -d)"
trap 'rm -rf "$os"' EXIT

assert_exit 0 "sign-r610-modules.sh parses" bash -n "$root/scripts/sign-r610-modules.sh"
assert_exit 0 "verify-r610-signatures.sh parses" bash -n "$root/scripts/verify-r610-signatures.sh"
assert_exit 0 "export-r610-modules.sh parses" bash -n "$root/scripts/export-r610-modules.sh"
assert_exit 0 "entrypoint.sh parses" bash -n "$root/entrypoint.sh"

out="$(bash "$root/scripts/sign-r610-modules.sh" --help)"
assert_contains "$out" "Never loads" "sign-r610 help is sign-only"
out="$(bash "$root/scripts/verify-r610-signatures.sh" --help)"
assert_contains "$out" "Never loads" "verify-r610 help is verify-only"

# README must not recommend disabling Secure Boot on this path.
if grep -nEi 'disable Secure Boot' "$root/README.md" | grep -viE 'do not|don'\''t|never'; then
    assert_eq "README disable-SB advice" "absent" "README must not recommend disabling Secure Boot"
else
    assert_eq "1" "1" "README must not recommend disabling Secure Boot"
fi
assert_file_contains "$root/README.md" 'scripts/sign-r610-modules.sh' "README documents host-side signing"
assert_file_contains "$root/docker-compose.yml" 'Do not mount MOK private keys' \
    "compose does not mount MOK keys"

# Throwaway test cert (never printed).
openssl req -new -x509 -newkey rsa:2048 -keyout "$os/key.pem" -out "$os/cert.pem" \
    -nodes -days 1 -subj "/CN=r610-test-mok" >/dev/null 2>&1
want_sha1="$(r610_cert_sha1 "$os/cert.pem")"
colon=""
i=0
while [ "$i" -lt "${#want_sha1}" ]; do
    colon="${colon}${colon:+:}${want_sha1:$i:2}"
    i=$((i + 2))
done
printf 'SHA1 Fingerprint: %s\n' "$colon" > "$os/mok-enrolled.txt"
printf 'SHA1 Fingerprint: 00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff:00:11:22:33\n' \
    > "$os/mok-other.txt"

cat > "$os/mokutil-pass" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
    --help)
        echo "Usage: mokutil [options]"
        echo "  --test-key <file>   Test if the key is enrolled"
        echo "  --list-enrolled     List enrolled keys"
        exit 0
        ;;
    --test-key)
        exit 0
        ;;
    --list-enrolled)
        cat "${os}/mok-enrolled.txt"
        exit 0
        ;;
esac
exit 2
STUB
cat > "$os/mokutil-fail" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
    --help)
        echo "Usage: mokutil [options]"
        echo "  --test-key <file>   Test if the key is enrolled"
        echo "  --list-enrolled     List enrolled keys"
        exit 0
        ;;
    --test-key)
        exit 1
        ;;
    --list-enrolled)
        cat "${os}/mok-other.txt"
        exit 0
        ;;
esac
exit 2
STUB
cat > "$os/mokutil-old" <<STUB
#!/usr/bin/env bash
# mokutil without --test-key (fingerprint fallback only)
case "\${1:-}" in
    --help)
        echo "Usage: mokutil [options]"
        echo "  --list-enrolled     List enrolled keys"
        exit 0
        ;;
    --test-key)
        echo "mokutil: invalid option --test-key" >&2
        exit 2
        ;;
    --list-enrolled)
        cat "${os}/mok-enrolled.txt"
        echo "        Subject: CN=r610-test-mok"
        exit 0
        ;;
esac
exit 2
STUB
cat > "$os/mokutil-old-miss" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
    --help)
        echo "Usage: mokutil [options]"
        echo "  --list-enrolled     List enrolled keys"
        exit 0
        ;;
    --test-key)
        exit 2
        ;;
    --list-enrolled)
        cat "${os}/mok-other.txt"
        echo "        Subject: CN=r610-test-mok"
        exit 0
        ;;
esac
exit 2
STUB
cat > "$os/modinfo" <<'STUB'
#!/usr/bin/env bash
field=""
ko=""
while [ $# -gt 0 ]; do
    case "$1" in
        -F) field="$2"; shift 2 ;;
        *) ko="$1"; shift ;;
    esac
done
[ -n "$ko" ] || exit 0
if [ -f "${ko}.${field}" ]; then
    cat "${ko}.${field}"
fi
exit 0
STUB
cat > "$os/sign-file" <<'STUB'
#!/usr/bin/env bash
# sign-file <hash> <key> <x509> <module> [<dest>]
mod="$4"
dest="${5:-$4}"
if [ -n "${5:-}" ]; then
    cp -f "$mod" "$dest"
fi
echo TestMOK > "${dest}.signer"
exit 0
STUB
chmod +x "$os/mokutil-pass" "$os/mokutil-fail" "$os/mokutil-old" "$os/mokutil-old-miss" "$os/modinfo" "$os/sign-file"

write_set() {
    local dir="$1"
    mkdir -p "$dir"
    local n
    for n in nvidia.ko nvidia-modeset.ko nvidia-drm.ko nvidia-uvm.ko; do
        printf 'dummy\n' > "$dir/$n"
        printf '610.57.04-apnex.1\n' > "$dir/$n.version"
    done
}

sign_set() {
    local dir="$1"
    local n
    for n in nvidia.ko nvidia-modeset.ko nvidia-drm.ko nvidia-uvm.ko; do
        printf 'TestMOK\n' > "$dir/$n.signer"
    done
}

export \
    MODINFO="$os/modinfo" \
    OPENSSL=openssl \
    R610_SIGN_FILE="$os/sign-file" \
    R610_SIGN_HASH=sha512 \
    R610_STAGING_ROOT="$os/staging" \
    R610_KERNEL_CONFIG="$os/kconfig" \
    SECURE_BOOT_FILE="$os/sb"

printf 'CONFIG_MODULE_SIG_HASH="sha512"\n' > "$os/kconfig"
assert_eq "$(r610_sign_hash_algo)" "sha512" "hash algo from kernel config"

# --- missing key / cert ---
export R610_MOK_KEY="$os/missing.key" R610_MOK_CERT="$os/missing.cert"
assert_eq "$(r610_mok_key_state)" "unavailable" "missing signing key"
assert_eq "$(r610_mok_cert_state)" "unavailable" "missing signing certificate"
assert_eq "$(r610_cert_enrolled_state)" "UNKNOWN" \
    "enrollment is UNKNOWN when the certificate is not readable"

# Unreadable (present, this uid cannot read) is not "missing" and not "unenrolled".
mkdir -p "$os/locked"
printf 'x\n' > "$os/locked/key.pem"
printf 'x\n' > "$os/locked/cert.der"
chmod a-rwx "$os/locked/key.pem" "$os/locked/cert.der"
export R610_MOK_KEY="$os/locked/key.pem" R610_MOK_CERT="$os/locked/cert.der"
assert_eq "$(r610_mok_key_state)" "unreadable" "unreadable signing key"
assert_eq "$(r610_mok_cert_state)" "unreadable" "unreadable signing certificate"
assert_eq "$(r610_cert_enrolled_state)" "UNKNOWN" \
    "enrollment is UNKNOWN when the certificate exists but is unreadable"
chmod u+rw "$os/locked/key.pem" "$os/locked/cert.der"

printf 'enabled\n' > "$os/sb"
write_set "$os/unsigned"
assert_exit 1 "sign fails when key is missing" \
    env R610_MOK_KEY="$os/missing.key" R610_MOK_CERT="$os/cert.pem" \
        bash "$root/scripts/sign-r610-modules.sh" --from "$os/unsigned" --dest "$os/signed"

export R610_MOK_KEY="$os/key.pem" R610_MOK_CERT="$os/missing.cert"
assert_eq "$(r610_mok_cert_state)" "unavailable" "missing cert with key present"
assert_exit 1 "sign fails when certificate is missing" \
    env R610_MOK_KEY="$os/key.pem" R610_MOK_CERT="$os/missing.cert" \
        bash "$root/scripts/sign-r610-modules.sh" --from "$os/unsigned" --dest "$os/signed"

# --- unenrolled certificate (mokutil --test-key nonzero) ---
export R610_MOK_KEY="$os/key.pem" R610_MOK_CERT="$os/cert.pem" MOKUTIL="$os/mokutil-fail"
assert_eq "$(r610_cert_enrolled_state "$os/cert.pem")" "FAIL" \
    "mokutil --test-key nonzero -> FAIL"
write_set "$os/signed-unenrolled"
sign_set "$os/signed-unenrolled"
assert_exit 1 "verify fails when certificate is not enrolled under Secure Boot" \
    env SECURE_BOOT_FILE="$os/sb" MOKUTIL="$os/mokutil-fail" \
        MODINFO="$os/modinfo" R610_MOK_CERT="$os/cert.pem" \
        bash "$root/scripts/verify-r610-signatures.sh" --dir "$os/signed-unenrolled"

# --- enrolled via --test-key exit 0 (authoritative, ignore English) ---
export MOKUTIL="$os/mokutil-pass"
assert_eq "$(r610_cert_enrolled_state "$os/cert.pem")" "PASS" \
    "mokutil --test-key exit 0 -> PASS"
assert_eq "$(r610_cert_identity "$os/cert.pem")" "r610-test-mok" "signing identity is cert CN"

# Explicit R610_MOK_CERT override (not automatic discovery)
assert_eq "$(R610_MOK_CERT="$os/cert.pem" r610_mok_cert_path)" "$os/cert.pem" \
    "R610_MOK_CERT overrides automatic discovery"

# Fallback: no --test-key, SHA1 match (CN present in list is not enough)
export MOKUTIL="$os/mokutil-old"
assert_eq "$(r610_mokutil_supports_test_key "$os/mokutil-old" && echo yes || echo no)" "no" \
    "old mokutil has no --test-key"
assert_eq "$(r610_cert_enrolled_state "$os/cert.pem")" "PASS" \
    "fallback SHA1 match is PASS when --test-key missing"
export MOKUTIL="$os/mokutil-old-miss"
assert_eq "$(r610_cert_enrolled_state "$os/cert.pem")" "FAIL" \
    "fallback does not treat CN/name match as enrollment"

# --- unsigned module set, Secure Boot enabled ---
export MOKUTIL="$os/mokutil-pass"
write_set "$os/unsigned"
assert_eq "$(r610_modules_built_state "$os/unsigned")" "yes" "unsigned tree is built"
assert_eq "$(r610_modules_signed_state "$os/unsigned" "610.57.04-apnex.1")" "PENDING" \
    "unsigned set is PENDING not PASS"
assert_exit 1 "verify unsigned set fails under Secure Boot" \
    env SECURE_BOOT_FILE="$os/sb" MOKUTIL="$os/mokutil-pass" \
        MODINFO="$os/modinfo" R610_MOK_CERT="$os/cert.pem" \
        bash "$root/scripts/verify-r610-signatures.sh" --dir "$os/unsigned"

# --- partially signed ---
write_set "$os/partial"
sign_set "$os/partial"
rm -f "$os/partial/nvidia-uvm.ko.signer"
assert_eq "$(r610_modules_signed_state "$os/partial" "610.57.04-apnex.1")" "FAIL" \
    "partially signed module set is FAIL"
assert_exit 1 "verify partial set fails" \
    env SECURE_BOOT_FILE="$os/sb" MOKUTIL="$os/mokutil-pass" \
        MODINFO="$os/modinfo" R610_MOK_CERT="$os/cert.pem" \
        bash "$root/scripts/verify-r610-signatures.sh" --dir "$os/partial"

# --- valid signed set + enrolled cert + Secure Boot enabled ---
write_set "$os/signed"
sign_set "$os/signed"
assert_eq "$(r610_modules_signed_state "$os/signed" "610.57.04-apnex.1")" "PASS" \
    "fully signed set is PASS"
assert_eq "$(r610_cert_enrolled_state "$os/cert.pem")" "PASS" "enrolled test cert is PASS"
assert_exit 0 "verify valid signed set under Secure Boot" \
    env SECURE_BOOT_FILE="$os/sb" MOKUTIL="$os/mokutil-pass" \
        MODINFO="$os/modinfo" R610_MOK_CERT="$os/cert.pem" \
        bash "$root/scripts/verify-r610-signatures.sh" --dir "$os/signed"

assert_eq "$(r610_milestone_b_sign_readiness enabled available available PASS yes PASS)" "PASS" \
    "Milestone B PASS when SB on and signed+enrolled"
assert_eq "$(r610_milestone_b_sign_readiness enabled available available PASS yes PENDING)" "FAIL" \
    "Milestone B FAIL when SB on and unsigned"
assert_eq "$(r610_milestone_b_sign_readiness enabled unavailable unavailable FAIL no PENDING)" "FAIL" \
    "Milestone B FAIL when key/cert missing under SB"
assert_eq "$(r610_milestone_b_sign_readiness enabled unreadable unreadable UNKNOWN no PENDING)" "FAIL" \
    "Milestone B FAIL when key/cert unreadable and modules not built"
assert_eq "$(r610_milestone_b_sign_readiness enabled available available PASS no PENDING)" "FAIL" \
    "Milestone B FAIL when enrolled but patched modules are not built yet"

# --- Secure Boot disabled: unsigned is allowed ---
printf 'disabled\n' > "$os/sb"
assert_exit 0 "verify unsigned set allowed when Secure Boot disabled" \
    env SECURE_BOOT_FILE="$os/sb" MOKUTIL="$os/mokutil-fail" \
        MODINFO="$os/modinfo" R610_MOK_CERT="$os/cert.pem" \
        bash "$root/scripts/verify-r610-signatures.sh" --dir "$os/unsigned"
assert_eq "$(r610_milestone_b_sign_readiness disabled unavailable unavailable UNKNOWN no PENDING)" "PASS" \
    "Milestone B PASS when Secure Boot disabled (signing optional)"
assert_eq "$(r610_sign_gate "$os/unsigned" "610.57.04-apnex.1" && echo ok)" "ok" \
    "sign gate permits unsigned when Secure Boot disabled"

# --- Secure Boot enabled: sign-file stub actually marks dest signed ---
printf 'enabled\n' > "$os/sb"
rm -rf "$os/signed-out"
assert_exit 0 "sign-r610 dry-run does not call sign-file" \
    env R610_MOK_KEY="$os/key.pem" R610_MOK_CERT="$os/cert.pem" \
        R610_SIGN_FILE="$os/sign-file" \
        bash "$root/scripts/sign-r610-modules.sh" --dry-run --from "$os/unsigned" --dest "$os/signed-out"
assert_exit 0 "sign-r610 signs with stub sign-file" \
    env R610_MOK_KEY="$os/key.pem" R610_MOK_CERT="$os/cert.pem" \
        R610_SIGN_FILE="$os/sign-file" \
        bash "$root/scripts/sign-r610-modules.sh" --from "$os/unsigned" --dest "$os/signed-out"
assert_file_contains "$os/signed-out/nvidia.ko.signer" "TestMOK" "stub sign-file marked nvidia.ko"

# export copies required modules and does not touch extra/nvidia
src="$os/from-build"
write_set "$src"
printf 'peermem\n' > "$src/nvidia-peermem.ko"
printf '610.57.04-apnex.1\n' > "$src/nvidia-peermem.ko.version"
assert_exit 0 "export copies from kernel-open tree" \
    bash "$root/scripts/export-r610-modules.sh" --from "$src" --dest "$os/exported"
assert_file_contains "$os/exported/nvidia.ko" "dummy" "export copied nvidia.ko"
[ -f "$os/exported/nvidia-peermem.ko" ]
assert_eq "$?" "0" "export copies optional peermem when present"

# mix stock + patched is FAIL
write_set "$os/mix"
sign_set "$os/mix"
printf '610.57.04\n' > "$os/mix/nvidia.ko.version"
assert_eq "$(r610_modules_signed_state "$os/mix" "610.57.04-apnex.1")" "FAIL" \
    "stock/patched mix is FAIL"

# preflight reports the signing table
assert_file_contains "$root/scripts/preflight-r610.sh" 'signing private key' \
    "preflight reports signing private key"
assert_file_contains "$root/scripts/preflight-r610.sh" 'Milestone B readiness' \
    "preflight reports Milestone B readiness"
assert_file_contains "$root/scripts/status-r610.sh" 'loaded module signatures' \
    "status-r610 verifies loaded signatures"
assert_file_contains "$root/entrypoint.sh" 'EXIT_MODULE_UNSIGNED' \
    "entrypoint fail-closes unsigned load under Secure Boot"
assert_file_contains "$root/entrypoint.sh" 'export-modules' \
    "entrypoint has build-only export-modules"

# helpers never echo PEM/DER key material
if grep -nE 'cat \$key|openssl rsa' "$root/tools/lib/module-sign.sh" \
        "$root/scripts/sign-r610-modules.sh"; then
    assert_eq "key dump" "absent" "signing helpers must not dump the private key"
else
    assert_eq "1" "1" "signing helpers must not dump the private key"
fi

finish_tests
