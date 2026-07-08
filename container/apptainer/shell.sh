#!/usr/bin/env bash
#
# shell.sh -- open an interactive shell inside the sandbox with the same
# read-only host view and writable /work as start.sh.
# Use this to drive the agent CLIs directly: claude, codex, gemini, agy.
#
# See start.sh for the read-only model and the autofs/NFS caveat.
# See common.sh for WORK/RO_PATHS defaults, bind, and env setup.
#
# Usage:
#   ./shell.sh
#   RO_PATHS="/groups/scicompsoft /nrs/scicompsoft" WORK=/scratch/$USER/work ./shell.sh
#   ./shell.sh --ro-paths "/groups/scicompsoft /nrs/scicompsoft"
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

exec apptainer shell \
    --contain \
    --home "$WORK/home:/work/home" \
    --env TMPDIR=/work/tmp \
    "${BIND_ARGS[@]}" \
    "${ENV_ARGS[@]}" \
    --pwd /work \
    "$SIF"
