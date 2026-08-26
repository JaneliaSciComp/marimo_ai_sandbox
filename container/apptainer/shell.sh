#!/usr/bin/env bash
#
# shell.sh -- open an interactive shell inside the sandbox with the same
# read-only host view and writable /work as start.sh.
# Use this to drive the agent CLIs directly: claude, codex, gemini, agy.
#
# See start.sh for the read-only model and the autofs/NFS caveat.
# See common.sh for WORK/RO_PATHS defaults, bind, and env setup.
#
# --cleanenv: see start.sh -- without it Apptainer inherits the entire
# calling environment, bypassing common.sh's ENV_PAIRS allowlist.
# --pid: see start.sh -- without it, `ps aux` in here shows the whole
# compute node's processes, not just this job's. Podman needs no
# equivalent; it isolates PIDs by default.
#
# Usage:
#   ./shell.sh
#   RO_PATHS="/groups/scicompsoft /nrs/scicompsoft" WORK=/scratch/$USER/work ./shell.sh
#   ./shell.sh --ro-paths "/groups/scicompsoft /nrs/scicompsoft" --work /scratch/$USER/work
set -euo pipefail

cd "$(dirname "$0")"

SIF="${SIF:-marimo_sandbox.sif}"

if [[ ! -f "$SIF" ]]; then
    echo ">> Image '$SIF' not found -- building now ..."
    bash ./build.sh
fi

# shellcheck source=common.sh
source "../common.sh"

BIND_ARGS=(); for p in "${BIND_PAIRS[@]}"; do BIND_ARGS+=(--bind "$p"); done
ENV_ARGS=();  for e in "${ENV_PAIRS[@]}"; do  ENV_ARGS+=(--env "$e"); done
GPU_ARGS=();  [[ "$HAS_GPU" == "1" ]] && GPU_ARGS+=(--nv)

[[ -f "$WORK/.marimo-pair.env" ]] && ENV_ARGS+=(--env-file "$WORK/.marimo-pair.env")

# See common.sh's write_bsub_runner_apptainer and container/bsub-wrapper/
# bin/bsub: when enabled, a wrapped `bsub ... -- <cmd>` re-enters this exact
# sandbox on whatever node LSF schedules it to.
[[ "$ENABLE_BSUB" == "1" ]] && write_bsub_runner_apptainer "$SIF"

exec apptainer shell \
    --contain \
    --cleanenv \
    --pid \
    --home "$WORK/home:/work/home" \
    --env TMPDIR=/work/tmp \
    "${BIND_ARGS[@]}" \
    "${ENV_ARGS[@]}" \
    "${GPU_ARGS[@]}" \
    --pwd /work \
    "$SIF"
