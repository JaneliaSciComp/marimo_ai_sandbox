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
#   ./shell.sh -- ttyd -p 7681 -W bash              # run a command instead of an interactive shell
#                                                    # (used by container/terminal-wrap.sh)
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

# common.sh deliberately does NOT strip a bare "--" (marimo.sh needs it to
# ride through unchanged into marimo's own CLI) -- but a command override
# for THIS script (see usage above) is naturally written with one
# (`./shell.sh -- ttyd ...`), so strip a single leading "--" here instead.
[[ "${1:-}" == "--" ]] && shift

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

# Any trailing args (after --allow/--ro-paths/--work are consumed by
# common.sh above) name a command to run instead of an interactive shell --
# e.g. `./shell.sh -- ttyd -p 7681 -W bash` for container/terminal-wrap.sh.
# Default (no override): entrypoint /bin/bash with ZERO trailing args, which
# starts an interactive shell -- this exact shape must be preserved
# unchanged (a bare `--entrypoint /bin/bash image bash` would instead try to
# run "bash" as a script argument to that bash, not start it interactively).
REAL_CMD=("$@")
if [[ -n "$PODMAN_INNER_ENTRYPOINT" ]]; then
    # Egress allowlist active: always go through the relay-starting wrapper
    # (which then execs the override command, or an interactive bash if
    # none was given) regardless of whether a command override was given.
    ENTRYPOINT_ARG="$PODMAN_INNER_ENTRYPOINT"
    [[ ${#REAL_CMD[@]} -eq 0 ]] && REAL_CMD=(bash)
    TRAILING_ARGS=("${PODMAN_INNER_ARGS[@]}" "${REAL_CMD[@]}")
elif [[ ${#REAL_CMD[@]} -gt 0 ]]; then
    ENTRYPOINT_ARG="${REAL_CMD[0]}"
    TRAILING_ARGS=("${REAL_CMD[@]:1}")
else
    ENTRYPOINT_ARG="/bin/bash"
    TRAILING_ARGS=()
fi

PODMAN_RUN_ARGS=(
    --rm -it
    --read-only
    --tmpfs /tmp
    --tmpfs /run
    --cgroup-manager=cgroupfs
    --events-backend=file
    "${PODMAN_NETWORK_ARGS[@]}"
    --entrypoint "$ENTRYPOINT_ARG"
    -e HOME=/work/home
    -e TMPDIR=/work/tmp
    -w /work
    "${BIND_ARGS[@]}"
    "${ENV_ARGS[@]}"
    "${GPU_ARGS[@]}"
    "$IMAGE"
    "${TRAILING_ARGS[@]}"
)

podman_run_watched PODMAN_RUN_ARGS
exit $?
