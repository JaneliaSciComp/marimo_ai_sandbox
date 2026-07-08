#!/usr/bin/env bash
#
# build.sh -- build the Marimo sandbox Apptainer image.
#
# Usage:
#   ./build.sh                # builds marimo_sandbox.sif from marimo.def
#   SIF=foo.sif ./build.sh    # custom output name
#
# Requires network access (downloads pixi, conda packages, npm packages and
# the Antigravity binary at build time) and unprivileged-build support
# (--fakeroot). On Janelia HPC, run on a node where `apptainer build
# --fakeroot` is permitted, or build elsewhere and copy the .sif over.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEF="${DEF:-$SCRIPT_DIR/marimo.def}"
SIF="${SIF:-$SCRIPT_DIR/marimo_sandbox.sif}"

# Run from the project root so %files paths (pixi.toml, pixi.lock, app) resolve.
cd "$SCRIPT_DIR/../.."

if [[ ! -f pixi.lock ]]; then
    echo "pixi.lock not found -- run 'pixi install' first." >&2
    exit 1
fi

# container/app is optional starter content; ensure it exists (even if empty)
# so the %files copy in marimo.def never fails on a missing source dir.
mkdir -p container/app

echo ">> Building ${SIF} from ${DEF} ..."
# Use local scratch for the build temp dir to avoid mksquashfs segfaults on NFS.
APPTAINER_TMPDIR="${APPTAINER_TMPDIR:-/scratch/$(id -un)/apptainer-tmp}"
mkdir -p "$APPTAINER_TMPDIR"
export APPTAINER_TMPDIR
# mksquashfs 4.7.5 (bundled with apptainer 1.5.1) segfaults on this host
# under multi-threaded operation; force single-processor mode to avoid it.
apptainer build --fakeroot --force --mksquashfs-args "-processors 1" "${SIF}" "${DEF}"

echo ">> Done. Image: $(readlink -f "${SIF}")"
echo ">> Run it with:  ./marimo.sh"
