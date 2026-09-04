# NVIDIA version helpers. Source from repo-root-relative tools.
# Expected variables after nvidia_version_load: NVIDIA_OPEN_TAG, NVIDIA_DRIVER_VERSION.

nvidia_version_file() {
    local root="${1:-}"
    if [ -z "$root" ]; then
        echo "nvidia_version_file: repo root required" >&2
        return 2
    fi
    echo "$root/nvidia-version.env"
}

nvidia_version_load() {
    local root="$1"
    local f
    f="$(nvidia_version_file "$root")"
    [ -f "$f" ] || { echo "nvidia-version: missing $f" >&2; return 1; }
    NVIDIA_OPEN_TAG=""
    NVIDIA_DRIVER_VERSION=""
    # shellcheck disable=SC1090
    set -a
    # Parse KEY=VAL lines; ignore comments and blanks.
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|\#*) continue ;;
        esac
        case "$line" in
            NVIDIA_OPEN_TAG=*|NVIDIA_DRIVER_VERSION=*)
                eval "$line"
                ;;
        esac
    done < "$f"
    set +a
    nvidia_version_validate_tag "${NVIDIA_OPEN_TAG:-}" || return 1
    nvidia_version_validate_tag "${NVIDIA_DRIVER_VERSION:-}" || return 1
    if [ "$NVIDIA_OPEN_TAG" != "$NVIDIA_DRIVER_VERSION" ]; then
        echo "nvidia-version: NVIDIA_OPEN_TAG ($NVIDIA_OPEN_TAG) != NVIDIA_DRIVER_VERSION ($NVIDIA_DRIVER_VERSION)" >&2
        return 1
    fi
}

# NVIDIA tags look like 610.57.04 (three numeric components).
nvidia_version_validate_tag() {
    local tag="$1"
    case "$tag" in
        [0-9]*.[0-9]*.[0-9]*)
            case "$tag" in
                *[!0-9.]*) echo "nvidia-version: invalid tag '$tag'" >&2; return 1 ;;
            esac
            return 0
            ;;
        *)
            echo "nvidia-version: invalid tag '$tag'" >&2
            return 1
            ;;
    esac
}

nvidia_dockerfile_tag() {
    local docker="${1:-}"
    [ -f "$docker" ] || { echo "nvidia-version: Dockerfile not found: $docker" >&2; return 1; }
    awk -F= '/^ARG NVIDIA_OPEN_TAG=/{print $2; exit}' "$docker"
}

nvidia_assert_dockerfile_aligned() {
    local root="$1"
    nvidia_version_load "$root" || return 1
    local dtag
    dtag="$(nvidia_dockerfile_tag "$root/Dockerfile")" || return 1
    if [ "$dtag" != "$NVIDIA_OPEN_TAG" ]; then
        echo "nvidia-version: Dockerfile ARG NVIDIA_OPEN_TAG=$dtag != nvidia-version.env $NVIDIA_OPEN_TAG" >&2
        return 1
    fi
}

nvidia_module_branch_suffix() {
    # A5 stamps NVIDIA_VERSION as ${NVIDIA_OPEN_TAG}-apnex.N
    echo "apnex.1"
}

nvidia_composed_module_version() {
    local root="$1"
    nvidia_version_load "$root" || return 1
    echo "${NVIDIA_OPEN_TAG}-$(nvidia_module_branch_suffix)"
}

# Currently loaded nvidia.ko version string, or "(not loaded)".
# Tests may set NVIDIA_LOADED_VERSION (including empty → "(not loaded)")
# to avoid calling modinfo / reading live /proc/modules.
nvidia_loaded_module_version() {
    local proc="${PROC_MODULES:-/proc/modules}"
    if [ "${NVIDIA_LOADED_VERSION+set}" = "set" ]; then
        if [ -n "$NVIDIA_LOADED_VERSION" ]; then
            printf '%s\n' "$NVIDIA_LOADED_VERSION"
        else
            printf '(not loaded)\n'
        fi
        return 0
    fi
    if grep -E '^nvidia ' "$proc" >/dev/null 2>&1; then
        modinfo -F version nvidia 2>/dev/null || printf 'unknown\n'
    else
        printf '(not loaded)\n'
    fi
}
