#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
root="$(cd "$here/.." && pwd)"

# dry-run wrappers must not require root and must not load modules
out="$(bash "$root/scripts/install-r610.sh" --help)"
assert_contains "$out" "Never loads nvidia.ko" "install-r610 help"
assert_exit 0 "install-r610 default dry-run" bash "$root/scripts/install-r610.sh"

out="$(bash "$root/scripts/remove-r610.sh" 2>&1)"
assert_contains "$out" "dry-run" "remove-r610 default dry-run"
assert_exit 0 "remove-r610 default exits 0" bash "$root/scripts/remove-r610.sh"

assert_exit 78 "install-r610 --load-module refuses" \
    bash "$root/scripts/install-r610.sh" --load-module
assert_exit 78 "install-r610 --load-module still refuses with ack" \
    bash "$root/scripts/install-r610.sh" --load-module --i-accept-host-kernel-risk
assert_exit 78 "remove-r610 --unload-module refuses" \
    bash "$root/scripts/remove-r610.sh" --unload-module
assert_exit 78 "remove-r610 --revert-cmdline refuses" \
    bash "$root/scripts/remove-r610.sh" --revert-cmdline

# Stage 4B scripts refuse without the freeze flag
assert_exit 78 "05-pinned-transfer refuses" \
    env -u I_ACCEPT_HOST_FREEZE_RISK bash "$root/diag/r610/05-pinned-transfer"
assert_exit 78 "06-compute-smoke refuses" \
    env -u I_ACCEPT_HOST_FREEZE_RISK bash "$root/diag/r610/06-compute-smoke"
assert_exit 78 "07-soak refuses" \
    env -u I_ACCEPT_HOST_FREEZE_RISK bash "$root/diag/r610/07-soak"

# validate-patchset accepts --nvidia-tag in usage (won't run a build here)
assert_file_contains "$root/tools/validate-patchset.sh" '--nvidia-tag' \
    "validate-patchset accepts --nvidia-tag"

assert_exit 0 "sign-r610 --help" bash "$root/scripts/sign-r610-modules.sh" --help
assert_exit 0 "verify-r610 --help" bash "$root/scripts/verify-r610-signatures.sh" --help
assert_exit 0 "export-r610 --help" bash "$root/scripts/export-r610-modules.sh" --help

finish_tests
