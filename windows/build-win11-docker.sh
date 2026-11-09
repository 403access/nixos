#!/usr/bin/env bash
#
# Run the Windows 11 slim-image build inside a Docker container so the host
# does not need wimlib, 7-Zip, xorriso or any other build dependency.
#
# All arguments are forwarded to build-win11.sh. Only paths that need bind
# mounts are translated: --iso, --out, --workdir and --unattend.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
IMAGE="${WIN11_BUILDER_IMAGE:-win11-slim-builder:bookworm}"

REBUILD=0
ISO_HOST=""
OUT_HOST=""
WORK_HOST=""
UNATTEND_HOST=""
BUILD_ARGS=()
MOUNTS=()

usage() {
    cat <<'USAGE'
Build a lean Windows 11 ISO in a Docker container.

Usage:
  ./build-win11-docker.sh --iso /path/to/Win11.iso [build-win11.sh options]

Docker options:
      --rebuild              Rebuild the builder image before running.
  -h, --help                 Show this help.

Every other option is passed through to build-win11.sh, for example:

  ./build-win11-docker.sh --iso ~/Downloads/Win11.iso --profile lean --locale de-DE

  ./build-win11-docker.sh --iso ~/Downloads/Win11.iso --profile micro \
      --experimental --solid --remove-winre

Run ./build-win11.sh --help for the full build option reference.

The source ISO is mounted read-only. Output goes to windows/out/ and work data
to windows/work/ on the host, exactly as with a native build. Paths passed via
--out, --workdir or --unattend outside the repository are mounted individually.

Environment:
  WIN11_BUILDER_IMAGE   Builder image tag (default: win11-slim-builder:bookworm)

Examples:
  ./build-win11-docker.sh --iso ~/Downloads/Win11_24H2.iso --profile safe
  ./build-win11-docker.sh --iso ~/Downloads/Win11_24H2.iso --rebuild --profile lean
USAGE
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '\n==> %s\n' "$*"
}

resolve_path() {
    local path="$1"
    local dir
    local base
    [[ "$path" != "/" ]] || die "refusing to use / as a file path"
    base="$(basename -- "$path")"
    case "$base" in
        ''|.|..) die "invalid file path: $path" ;;
    esac
    dir="$(dirname -- "$path")"
    mkdir -p -- "$dir" || die "cannot create directory: $dir"
    dir="$(cd -- "$dir" && pwd -P)" || die "cannot resolve directory: $dir"
    printf '%s/%s\n' "$dir" "$base"
}

resolve_dir_path() {
    local path="$1"
    [[ "$path" != "/" ]] || die "refusing to use / as --workdir"
    mkdir -p -- "$path" || die "cannot create directory: $path"
    (cd -- "$path" && pwd -P) || die "cannot resolve directory: $path"
}

# Translate a host path to the path it has inside the container. Paths inside
# the repository use the /repo bind mount; anything else is mounted at the
# supplied mount point with the same basename.
container_path() {
    local host="$1"
    local mount="$2"
    case "$host" in
        "$REPO_ROOT")
            printf '/repo\n'
            ;;
        "$REPO_ROOT"/*)
            printf '/repo/%s\n' "${host#"$REPO_ROOT"/}"
            ;;
        *)
            printf '%s/%s\n' "$mount" "$(basename -- "$host")"
            ;;
    esac
}

is_inside_repo() {
    case "$1" in
        "$REPO_ROOT"|"$REPO_ROOT"/*) return 0 ;;
        *) return 1 ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rebuild)
            REBUILD=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -i|--iso)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            ISO_HOST="$2"
            shift 2
            ;;
        -o|--out|--output)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            OUT_HOST="$2"
            shift 2
            ;;
        -w|--workdir)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            WORK_HOST="$2"
            shift 2
            ;;
        --unattend)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            UNATTEND_HOST="$2"
            shift 2
            ;;
        --)
            shift
            while [[ $# -gt 0 ]]; do
                BUILD_ARGS+=("$1")
                shift
            done
            ;;
        *)
            BUILD_ARGS+=("$1")
            shift
            ;;
    esac
done

[[ -n "$ISO_HOST" ]] || die "--iso is required (try --help)"
[[ -f "$ISO_HOST" ]] || die "source ISO not found: $ISO_HOST"
ISO_HOST="$(cd -- "$(dirname -- "$ISO_HOST")" && pwd -P)/$(basename -- "$ISO_HOST")"

command -v docker >/dev/null 2>&1 || die "docker not found; install Docker Desktop, OrbStack, Colima, or Docker Engine"
docker info >/dev/null 2>&1 || die "cannot reach the Docker daemon; start Docker Desktop, OrbStack, Colima, or dockerd"

if [[ "$REBUILD" -eq 1 ]] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    log "Building builder image: $IMAGE"
    docker build -t "$IMAGE" -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR"
fi

CONTAINER_ARGS=(--iso "/iso/$(basename -- "$ISO_HOST")")
MOUNTS+=(-v "$(dirname -- "$ISO_HOST"):/iso:ro")

if [[ -n "$OUT_HOST" ]]; then
    OUT_HOST="$(resolve_path "$OUT_HOST")"
    CONTAINER_ARGS+=(--out "$(container_path "$OUT_HOST" /output)")
    if ! is_inside_repo "$OUT_HOST"; then
        MOUNTS+=(-v "$(dirname -- "$OUT_HOST"):/output")
    fi
fi

if [[ -n "$WORK_HOST" ]]; then
    WORK_HOST="$(resolve_dir_path "$WORK_HOST")"
    case "$WORK_HOST" in
        "$HOME"|"$REPO_ROOT"|"$SCRIPT_DIR")
            die "refusing to use a broad directory as --workdir: $WORK_HOST"
            ;;
    esac
    CONTAINER_ARGS+=(--workdir "$(container_path "$WORK_HOST" /work)")
    if ! is_inside_repo "$WORK_HOST"; then
        MOUNTS+=(-v "$(dirname -- "$WORK_HOST"):/work")
    fi
fi

if [[ -n "$UNATTEND_HOST" ]]; then
    [[ -f "$UNATTEND_HOST" ]] || die "unattend file not found: $UNATTEND_HOST"
    UNATTEND_HOST="$(cd -- "$(dirname -- "$UNATTEND_HOST")" && pwd -P)/$(basename -- "$UNATTEND_HOST")"
    CONTAINER_ARGS+=(--unattend "$(container_path "$UNATTEND_HOST" /unattend)")
    if ! is_inside_repo "$UNATTEND_HOST"; then
        MOUNTS+=(-v "$(dirname -- "$UNATTEND_HOST"):/unattend:ro")
    fi
fi

TTY_FLAGS=()
if [[ -t 0 && -t 1 ]]; then
    TTY_FLAGS=(-it)
fi

log "Running build in $IMAGE"
docker run --rm ${TTY_FLAGS[@]+"${TTY_FLAGS[@]}"} \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    -v "$REPO_ROOT:/repo" \
    ${MOUNTS[@]+"${MOUNTS[@]}"} \
    -w /repo/windows \
    "$IMAGE" \
    ./build-win11.sh \
    ${CONTAINER_ARGS[@]+"${CONTAINER_ARGS[@]}"} \
    ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}
