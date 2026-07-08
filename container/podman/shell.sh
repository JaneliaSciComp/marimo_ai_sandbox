#!/usr/bin/env bash
#
# shell_podman.sh -- open an interactive shell inside the sandbox via Podman
# with the same read-only host view and writable /work as run_podman.sh.
# Use this to drive the agent CLIs directly: claude, codex, gemini, agy.
#
# See common.sh for WORK/RO_PATHS defaults, bind, and env setup.
#
# Usage:
#   ./shell_podman.sh
#   RO_PATHS="/groups/scicompsoft /nrs/scicompsoft" WORK=/scratch/$USER/work ./shell_podman.sh
#   ./shell_podman.sh --ro-paths "/groups/scicompsoft /nrs/scicompsoft" --work /scratch/$USER/work
set -euo pipefail

cd "$(dirname "$0")"

IMAGE="${IMAGE:-marimo_sandbox:latest}"

# Podman on Janelia HPC: fix missing XDG_RUNTIME_DIR and redirect storage off NFS.
if [[ -z "${XDG_RUNTIME_DIR:-}" ]] || [[ ! -d "$XDG_RUNTIME_DIR" ]]; then
    export XDG_RUNTIME_DIR="/tmp/podman-run-$(id -u)"
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
fi
PODMAN_STORAGE_ROOT="${PODMAN_STORAGE_ROOT:-/scratch/$(id -un)/podman-storage}"
PODMAN_RUN_ROOT="${PODMAN_RUN_ROOT:-/tmp/podman-run-$(id -u)/run}"
mkdir -p "$PODMAN_STORAGE_ROOT" "$PODMAN_RUN_ROOT"
STORAGE_CONF="$(mktemp /tmp/podman-storage-XXXXXX.conf)"
trap 'rm -f "$STORAGE_CONF"' EXIT
cat > "$STORAGE_CONF" <<EOF
[storage]
driver = "overlay"
graphRoot = "$PODMAN_STORAGE_ROOT"
runRoot  = "$PODMAN_RUN_ROOT"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
ignore_chown_errors = "true"
EOF
export CONTAINERS_STORAGE_CONF="$STORAGE_CONF"

# shellcheck source=common.sh
source "../common.sh"

if ! podman image exists "$IMAGE" &>/dev/null; then
    echo ">> Image '$IMAGE' not found -- building now ..."
    bash ./build.sh
fi

BIND_ARGS=(); for p in "${BIND_PAIRS[@]}"; do BIND_ARGS+=(-v "$p"); done
ENV_ARGS=();  for e in "${ENV_PAIRS[@]}"; do  ENV_ARGS+=(-e "$e"); done

exec podman run \
    --rm -it \
    --read-only \
    --tmpfs /tmp \
    --tmpfs /run \
    --cgroup-manager=cgroupfs \
    --events-backend=file \
    --net=host \
    --entrypoint /bin/bash \
    -e HOME=/work/home \
    -e TMPDIR=/work/tmp \
    -w /work \
    "${BIND_ARGS[@]}" \
    "${ENV_ARGS[@]}" \
    "$IMAGE"
