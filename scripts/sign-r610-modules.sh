#!/usr/bin/env bash
# sign-r610-modules.sh — host-side MOK sign of patched NVIDIA modules.
#
# Sign-only. Never loads or unloads nvidia.ko. Never bind-mounts the
# private key into the injector build container.
#
#   sudo ./scripts/sign-r610-modules.sh --from DIR [--dest DIR]
#   ./scripts/sign-r610-modules.sh --dry-run --from DIR
#
# Uses the running kernel's sign-file and CONFIG_MODULE_SIG_HASH (sha512
# on Fedora 44 / Linux 7.1). Discovers an existing enrolled MOK
# (akmods, DKMS, or R610_MOK_KEY / R610_MOK_CERT). Does not generate or
# enroll a new key (that would require a reboot through MOK Manager).
#
# Do not disable Secure Boot. Stock extra/nvidia/ is not overwritten.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../tools/lib/platform.sh
. "$REPO_ROOT/tools/lib/platform.sh"
# shellcheck source=../tools/lib/nvidia-version.sh
. "$REPO_ROOT/tools/lib/nvidia-version.sh"
# shellcheck source=../tools/lib/module-sign.sh
. "$REPO_ROOT/tools/lib/module-sign.sh"

FROM=""
DEST=""
DRY_RUN=0

usage() {
    sed -n '/^# sign-r610/,/^set -euo/p' "$0" | sed 's/^# \?//' | head -n -1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from) FROM="${2:-}"; shift 2 ;;
        --dest) DEST="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

FROM="${FROM:-$(r610_staging_unsigned)}"
DEST="${DEST:-$(r610_staging_signed)}"

nvidia_version_load "$REPO_ROOT"
expected="$(nvidia_composed_module_version "$REPO_ROOT")"
sb="$(platform_secure_boot_state)"
hash="$(r610_sign_hash_algo)"
sf="$(r610_sign_file_path)"
key_state="$(r610_mok_key_state)"
cert_state="$(r610_mok_cert_state)"

echo "== sign-r610-modules (sign-only, no module load) =="
echo "  Secure Boot=$sb"
echo "  hash=$hash"
echo "  sign-file=$sf"
echo "  key=$key_state"
echo "  cert=$cert_state"
echo "  from=$FROM"
echo "  dest=$DEST"
echo "  expected version=$expected"

if [[ ! -d "$FROM" ]]; then
    echo "sign-r610-modules: source dir missing: $FROM" >&2
    exit 1
fi

missing=0
while IFS= read -r name; do
    if [[ ! -f "$FROM/$name" ]]; then
        echo "missing required $name" >&2
        missing=1
    fi
done < <(r610_required_ko_names)
if [[ "$missing" -ne 0 ]]; then
    echo "export patched modules first: $REPO_ROOT/scripts/export-r610-modules.sh --from <kernel-open>" >&2
    exit 1
fi

if [[ "$key_state" != "available" || "$cert_state" != "available" ]]; then
    echo "sign-r610-modules: signing key or certificate unavailable." >&2
    echo "  Set R610_MOK_KEY and R610_MOK_CERT, or run as root so akmods/DKMS MOK is readable." >&2
    echo "  Do not disable Secure Boot." >&2
    exit 1
fi

if [[ ! -x "$sf" ]]; then
    echo "sign-r610-modules: sign-file not executable: $sf" >&2
    exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] would sign:"
    while IFS= read -r name; do
        [[ -f "$FROM/$name" ]] || continue
        echo "  $name"
    done < <(r610_all_ko_names)
    echo "[dry-run] not calling sign-file"
    exit 0
fi

# sign-file is invoked with key path only; xtrace is forced off.
set +x
if ! r610_sign_module_dir "$FROM" "$DEST"; then
    echo "sign-r610-modules: sign-file failed (module name only; key not logged)" >&2
    exit 1
fi

echo "signed modules → $DEST"
echo "next: $REPO_ROOT/scripts/verify-r610-signatures.sh --dir $DEST"
exit 0
