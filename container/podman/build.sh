#!/usr/bin/env bash
#
# build_podman.sh -- build the Marimo sandbox Podman image.
#
# Usage:
#   ./build_podman.sh                  # builds marimo_sandbox:latest from Containerfile
#   IMAGE=foo:latest ./build_podman.sh # custom image tag
#
set -euo pipefail

cd "$(dirname "$0")"

IMAGE="${IMAGE:-marimo_sandbox:latest}"
FILE="${FILE:-Containerfile}"

# pixi.lock lives at the project root (two levels up), which is also the
# Podman build context (see the `podman build` invocation below).
if [[ ! -f ../../pixi.lock ]]; then
    echo "pixi.lock not found -- run 'pixi install' first." >&2
    exit 1
fi

# container/app is optional starter content; ensure it exists (even if empty)
# so the Containerfile's `COPY container/app /opt/app/app` never fails on a
# missing source dir.
mkdir -p ../app

# Set XDG_RUNTIME_DIR if the default one is missing or inaccessible (necessary for Janelia HPC compute nodes)
if [[ -z "${XDG_RUNTIME_DIR:-}" ]] || [[ ! -d "$XDG_RUNTIME_DIR" ]]; then
    export XDG_RUNTIME_DIR="/tmp/podman-run-$(id -u)"
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
fi

# Redirect Podman storage to a local (non-NFS) filesystem so that overlay/xattr operations work.
# The default ~/.local/share/containers is on NFS at Janelia, which doesn't support lsetxattr.
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
# Required on Janelia HPC: no /etc/subuid entries means we can't lchown inside the user namespace
ignore_chown_errors = "true"
EOF
export CONTAINERS_STORAGE_CONF="$STORAGE_CONF"
echo ">> Using local Podman storage at ${PODMAN_STORAGE_ROOT}"

echo ">> Building Podman image ${IMAGE} from ${FILE} ..."
# --cgroup-manager=cgroupfs: no systemd user session on Janelia HPC compute nodes
# --events-backend=file:    no dbus session available
podman build \
    --cgroup-manager=cgroupfs \
    --events-backend=file \
    -t "${IMAGE}" -f "${FILE}" ../..

echo ">> Done. Image: ${IMAGE}"
echo ">> Run it with:  ./marimo.sh"
