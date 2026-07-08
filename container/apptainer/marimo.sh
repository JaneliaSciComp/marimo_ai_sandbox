#!/usr/bin/env bash
#
# start.sh -- launch the Marimo sandbox with a read-only view of the host
# filesystem and a single writable work directory.
#
# Read-only model:
#   * --contain isolates the container: the host home and CWD are NOT mounted,
#     /tmp is a private tmpfs.
#   * Each path in RO_PATHS is bind-mounted READ-ONLY so agents and notebooks
#     can read code/data but cannot modify the host.
#   * ./work (override with WORK=...) is the ONLY writable mount, exposed at
#     /work. HOME is set to /work/home (via --home, which is the ONLY way that
#     works -- apptainer refuses to set HOME via --env) and TMPDIR to /work/tmp,
#     so Marimo notebooks, agent edits and the agents' config/cache all persist
#     under ./work.
#
# READ-ONLY CAVEAT (Janelia / autofs + NFS):
#   /groups, /nrs, /scratch are autofs parents with a SEPARATE NFS mount per
#   lab. A read-only bind is NOT recursive, so binding "/groups:ro" leaves the
#   nested per-lab NFS mounts WRITABLE -- a silent leak. You must bind the
#   LEAF per-lab paths (e.g. /groups/scicompsoft). This script refuses bare
#   autofs parents to avoid that footgun.
#
# See common.sh for WORK/PORT/RO_PATHS defaults, bind, and env setup.
#
# Usage:
#   ./start.sh                                  # serve Marimo on :8080
#   RO_PATHS="/groups/scicompsoft /nrs/scicompsoft" ./start.sh
#   WORK=/scratch/$USER/work ./start.sh
#   PORT=9000 ./start.sh
#   ./start.sh --port 8888                      # extra args go to marimo
set -euo pipefail

cd "$(dirname "$0")"

SIF="${SIF:-marimo_sandbox.sif}"

if [[ ! -f "$SIF" ]]; then
    echo ">> Image '$SIF' not found -- building now ..."
    bash "$(dirname "$0")/build.sh"
fi

# shellcheck source=common.sh
source "../common.sh"

BIND_ARGS=(); for p in "${BIND_PAIRS[@]}"; do BIND_ARGS+=(--bind "$p"); done
ENV_ARGS=();  for e in "${ENV_PAIRS[@]}"; do  ENV_ARGS+=(--env "$e"); done

echo ">> Serving Marimo on http://0.0.0.0:${PORT}  (work dir: $WORK)"
echo ">> Read-only host binds:${RO_PATHS:- (none)}"
exec apptainer run \
    --contain \
    --home "$WORK/home:/work/home" \
    --env TMPDIR=/work/tmp \
    "${BIND_ARGS[@]}" \
    "${ENV_ARGS[@]}" \
    "$SIF" --port "$PORT" "$@"
