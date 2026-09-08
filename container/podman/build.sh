#!/usr/bin/env bash
#
# build.sh -- build the Marimo sandbox Podman image.
#
# Usage:
#   ./build.sh                  # builds marimo_sandbox:latest from Containerfile
#   IMAGE=foo:latest ./build.sh # custom image tag
#
set -euo pipefail

source "$(dirname "$0")/../usage-lib.sh"
[[ "${1:-}" =~ ^(-h|--help)$ ]] && print_usage_and_exit "$0"

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

# shellcheck source=lib.sh
source "./lib.sh"

# Redirects storage off NFS, reconciles staleness after a node reboot -- see
# lib.sh's podman_storage_setup. A build only needs the shared, durable
# store (no per-job isolation -- that's for concurrent `podman run`s, see
# marimo.sh/shell.sh).
podman_storage_setup
trap 'rm -f "$PODMAN_STORAGE_CONF_FILE" 2>/dev/null; true' EXIT
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
