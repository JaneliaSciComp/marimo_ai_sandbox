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
# Image source: by default this pulls the image published by
# .github/workflows/publish-image.yml (ghcr.io/janeliascicomp/marimo_ai_sandbox)
# instead of building from source. If the pull fails (offline compute node,
# registry unreachable) and no local copy exists yet, it falls back to
# building marimo_sandbox:latest locally via build.sh, same as before this
# registry image existed. Set IMAGE to any other reference to pull that
# instead, or to a purely local tag (e.g. marimo_sandbox:latest) to skip the
# registry and always build locally on first use.
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
#   IMAGE=marimo_sandbox:latest ./run_podman.sh       # skip the registry, build locally
set -euo pipefail

cd "$(dirname "$0")"

IMAGE="${IMAGE:-ghcr.io/janeliascicomp/marimo_ai_sandbox:latest}"
LOCAL_IMAGE="marimo_sandbox:latest"

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
    echo ">> Image '$IMAGE' not found locally -- pulling from registry ..."
    if ! podman pull "$IMAGE"; then
        echo ">> Pull failed -- building '$LOCAL_IMAGE' from source instead ..." >&2
        IMAGE="$LOCAL_IMAGE"
        podman image exists "$IMAGE" &>/dev/null || bash ./build.sh
    fi
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
