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
#   ./shell.sh --allow litellm.int.janelia.org      # restrict egress to just this host
set -euo pipefail

# Captured before the cd below so common.sh can resolve a relative --work
# path against where the user actually ran this from, not this script's dir.
_CALLER_PWD="$PWD"

cd "$(dirname "$0")"

SIF="${SIF:-marimo_sandbox.sif}"

if [[ ! -f "$SIF" ]]; then
    echo ">> Image '$SIF' not found -- building now ..."
    bash ./build.sh
fi

# shellcheck source=common.sh
source "../common.sh"
# shellcheck source=lib.sh
source "./lib.sh"

BIND_ARGS=(); for p in "${BIND_PAIRS[@]}"; do BIND_ARGS+=(--bind "$p"); done
ENV_ARGS=();  for e in "${ENV_PAIRS[@]}"; do  ENV_ARGS+=(--env "$e"); done
GPU_ARGS=();  [[ "$HAS_GPU" == "1" ]] && GPU_ARGS+=(--nv)

[[ -f "$WORK/.marimo-pair.env" ]] && ENV_ARGS+=(--env-file "$WORK/.marimo-pair.env")

# Off by default (unrestricted, shared host network): see lib.sh's
# apptainer_network_setup.
apptainer_network_setup
trap apptainer_network_cleanup EXIT

# See common.sh's write_bsub_runner_apptainer and container/bsub-wrapper/
# bin/bsub: when enabled, a wrapped `bsub ... -- <cmd>` re-enters this exact
# sandbox on whatever node LSF schedules it to.
[[ "$ENABLE_BSUB" == "1" ]] && write_bsub_runner_apptainer "$SIF"

if [[ ${#APPTAINER_EXEC_WRAP[@]} -gt 0 ]]; then
    # Egress allowlist active: start the in-container relay (and export
    # http_proxy/https_proxy) before dropping into the interactive shell.
    # `apptainer shell` has no hook for this, so use `apptainer exec .../bin/bash`
    # instead -- not exec'd here (unlike the default branch below), so the
    # EXIT trap above can stop the host-side proxy once the shell exits.
    apptainer exec \
        --contain \
        --cleanenv \
        --pid \
        --home "$WORK/home:/work/home" \
        --env TMPDIR=/work/tmp \
        "${APPTAINER_NET_ARGS[@]}" \
        "${BIND_ARGS[@]}" \
        "${APPTAINER_BIND_EXTRA[@]}" \
        "${ENV_ARGS[@]}" \
        "${GPU_ARGS[@]}" \
        --pwd /work \
        "$SIF" /bin/bash "${APPTAINER_EXEC_WRAP[@]}" bash
    exit $?
fi

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
