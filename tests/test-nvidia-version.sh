#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
. "$here/../tools/lib/nvidia-version.sh"

root="$(cd "$here/.." && pwd)"

nvidia_version_load "$root"
assert_eq "$NVIDIA_OPEN_TAG" "610.57.04" "nvidia-version.env OPEN_TAG"
assert_eq "$NVIDIA_DRIVER_VERSION" "610.57.04" "nvidia-version.env DRIVER_VERSION"

nvidia_assert_dockerfile_aligned "$root"
assert_eq "$?" "0" "Dockerfile ARG matches nvidia-version.env"

dtag="$(nvidia_dockerfile_tag "$root/Dockerfile")"
assert_eq "$dtag" "610.57.04" "Dockerfile ARG NVIDIA_OPEN_TAG"

composed="$(nvidia_composed_module_version "$root")"
assert_eq "$composed" "610.57.04-apnex.1" "composed module version"

nvidia_version_validate_tag "610.57.04"
assert_eq "$?" "0" "validate 610.57.04"
nvidia_version_validate_tag "595.71.05"
assert_eq "$?" "0" "validate 595.71.05"

nvidia_version_validate_tag "not-a-tag" 2>/dev/null
assert_eq "$?" "1" "reject non-numeric tag"
nvidia_version_validate_tag "610.57.04-apnex.1" 2>/dev/null
assert_eq "$?" "1" "reject apnex suffix as source tag"

# mismatch NVIDIA_OPEN_TAG vs DRIVER_VERSION
d="$(mktemp -d)"
trap 'rm -rf "$d"' EXIT
printf 'NVIDIA_OPEN_TAG=610.57.04\nNVIDIA_DRIVER_VERSION=595.71.05\n' > "$d/nvidia-version.env"
nvidia_version_load "$d" 2>/dev/null
assert_eq "$?" "1" "reject OPEN_TAG != DRIVER_VERSION"

# Dockerfile drift
printf 'NVIDIA_OPEN_TAG=610.57.04\nNVIDIA_DRIVER_VERSION=610.57.04\n' > "$d/nvidia-version.env"
printf 'ARG NVIDIA_OPEN_TAG=595.71.05\n' > "$d/Dockerfile"
nvidia_assert_dockerfile_aligned "$d" 2>/dev/null
assert_eq "$?" "1" "reject Dockerfile ARG drift"

assert_file_contains "$root/entrypoint.sh" 'fw_upstream="${NVIDIA_OPEN_TAG' \
    "entrypoint firmware uses NVIDIA_OPEN_TAG"
assert_file_contains "$root/docker-compose.yml" '610.57.04-apnex.1' \
    "compose image tag is 610.57.04-apnex.1"
assert_file_contains "$root/k8s/daemonset.yaml" '610.57.04-apnex.1' \
    "daemonset image tag is 610.57.04-apnex.1"

finish_tests
