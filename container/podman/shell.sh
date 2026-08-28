#!/usr/bin/env bash
#
# shell.sh -- open an interactive shell inside the sandbox via Podman
# with the same read-only host view and writable /work as marimo.sh.
# Use this to drive the agent CLIs directly: claude, codex, gemini, agy.
#
# See ../common.sh for WORK/RO_PATHS/ALLOW_HOSTS defaults, bind, and env
# setup, and ./lib.sh for the Podman storage/watchdog/network-allowlist
# helpers used below.
#
# Usage:
#   ./shell.sh
#   RO_PATHS="/groups/scicompsoft /nrs/scicompsoft" WORK=/scratch/$USER/work ./shell.sh
#   ./shell.sh --ro-paths "/groups/scicompsoft /nrs/scicompsoft" --work /scratch/$USER/work
#   ./shell.sh --allow litellm.int.janelia.org      # restrict egress to just this host
set -euo pipefail

# Save the real stdin before podman run backgrounds (needed for lib.sh's
# podman_run_watched catatonit watchdog) -- bash silently redirects a
# backgrounded job's stdin from /dev/null otherwise, breaking the
# interactive session.
exec 3<&0

# Captured before the cd below so common.sh can resolve a relative --work
# path against where the user actually ran this from, not this script's dir.
_CALLER_PWD="$PWD"

cd "$(dirname "$0")"

IMAGE="${IMAGE:-marimo_sandbox:latest}"

# shellcheck source=common.sh
source "../common.sh"
# shellcheck source=lib.sh
source "./lib.sh"

podman_storage_setup_job
cleanup() {
    podman_network_cleanup
    podman_storage_cleanup
    rm -f "$PODMAN_STORAGE_CONF_FILE" 2>/dev/null
    true
}
trap cleanup EXIT

if ! podman image exists "$IMAGE" &>/dev/null; then
    echo ">> Image '$IMAGE' not found -- building now ..."
    bash ./build.sh
fi

BIND_ARGS=(); for p in "${BIND_PAIRS[@]}"; do BIND_ARGS+=(-v "$p"); done
ENV_ARGS=();  for e in "${ENV_PAIRS[@]}"; do  ENV_ARGS+=(-e "$e"); done
[[ -f "$WORK/.marimo-pair.env" ]] && ENV_ARGS+=(--env-file "$WORK/.marimo-pair.env")
# See marimo.sh for why CDI (--device nvidia.com/gpu=all) rather than --gpus.
GPU_ARGS=();  [[ "$HAS_GPU" == "1" ]] && GPU_ARGS+=(--device nvidia.com/gpu=all)

# Off by default (--net=host, unchanged): see lib.sh's podman_network_setup.
podman_network_setup

# See common.sh's write_bsub_runner_podman and container/bsub-wrapper/bin/
# bsub: when enabled, a wrapped `bsub ... -- <cmd>` re-enters this exact
# sandbox on whatever node LSF schedules it to.
[[ "$ENABLE_BSUB" == "1" ]] && write_bsub_runner_podman "$IMAGE"

PODMAN_RUN_ARGS=(
    --rm -it
    --read-only
    --tmpfs /tmp
    --tmpfs /run
    --cgroup-manager=cgroupfs
    --events-backend=file
    "${PODMAN_NETWORK_ARGS[@]}"
    --entrypoint /bin/bash
    -e HOME=/work/home
    -e TMPDIR=/work/tmp
    -w /work
    "${BIND_ARGS[@]}"
    "${ENV_ARGS[@]}"
    "${GPU_ARGS[@]}"
    "$IMAGE"
)
# Egress allowlist active: start the in-container relay (and export
# http_proxy/https_proxy) before dropping into the interactive shell.
[[ -n "$PODMAN_INNER_ENTRYPOINT" ]] && PODMAN_RUN_ARGS+=("${PODMAN_INNER_ARGS[@]}" bash)

podman_run_watched PODMAN_RUN_ARGS
exit $?
