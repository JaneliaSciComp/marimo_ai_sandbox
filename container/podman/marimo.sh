#!/usr/bin/env bash
#
# run_podman.sh -- launch the Marimo sandbox via Podman with a read-only view
# of the host filesystem and a single writable work directory.
#
# See start.sh for the read-only model and the autofs/NFS caveat.
# See common.sh for WORK/PORT/RO_PATHS defaults, bind, and env setup.
#
# Janelia HPC notes:
#   --cgroup-manager=cgroupfs  no systemd user session on compute nodes
#   --events-backend=file      no dbus session available
#   --userns=keep-id omitted   requires /etc/subuid entries absent on this host
#   Storage redirected to /scratch to avoid NFS xattr failures
#
# Usage:
#   ./run_podman.sh                                  # serve Marimo on :8080
#   RO_PATHS="/groups/scicompsoft /nrs/scicompsoft" ./run_podman.sh
#   ./run_podman.sh --ro-paths "/groups/scicompsoft /nrs/scicompsoft"
#   WORK=/scratch/$USER/work ./run_podman.sh
#   ./run_podman.sh --work /scratch/$USER/work
#   PORT=9000 ./run_podman.sh
#   ./run_podman.sh --port 9000
#   ./run_podman.sh --extra-marimo-flag              # unrecognized args go to marimo
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

echo ">> Serving Marimo on http://0.0.0.0:${PORT}  (work dir: $WORK)"
echo ">> Read-only host binds:${RO_PATHS:- (none)}"
exec podman run \
    --rm -it \
    --read-only \
    --tmpfs /tmp \
    --tmpfs /run \
    --cgroup-manager=cgroupfs \
    --events-backend=file \
    --net=host \
    -e HOME=/work/home \
    -e TMPDIR=/work/tmp \
    -w /work \
    "${BIND_ARGS[@]}" \
    "${ENV_ARGS[@]}" \
    "$IMAGE" --port "$PORT" "$@"
