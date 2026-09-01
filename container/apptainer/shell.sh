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
#   ./shell.sh -- ttyd -p 7681 -W bash              # run a command instead of an interactive shell
#                                                    # (used by container/terminal-wrap.sh)
set -euo pipefail

source "$(dirname "$0")/../usage-lib.sh"
[[ "${1:-}" =~ ^(-h|--help)$ ]] && print_usage_and_exit "$0"

# Captured before the cd below so common.sh can resolve a relative --work
# path against where the user actually ran this from, not this script's dir.
_CALLER_PWD="$PWD"

cd "$(dirname "$0")"

_SIF_EXPLICIT=0; [[ -n "${SIF:-}" ]] && _SIF_EXPLICIT=1
SIF="${SIF:-marimo_sandbox.sif}"
REMOTE_IMAGE="${REMOTE_IMAGE:-docker://ghcr.io/janeliascicomp/marimo_ai_sandbox:latest}"

# Reports coarse progress to Fileglancer's phase file (set only when this
# runs as a Fileglancer service job -- see container/terminal-wrap.sh, which
# also sets this before driving this script). A no-op everywhere else.
_set_phase() {
    [[ -n "${FG_PHASE_PATH:-}" ]] && printf '%s' "$1" > "$FG_PHASE_PATH" 2>/dev/null
    return 0
}

# shellcheck source=common.sh
source "../common.sh"
# shellcheck source=lib.sh
source "./lib.sh"

# common.sh deliberately does NOT strip a bare "--" (marimo.sh needs it to
# ride through unchanged into marimo's own CLI) -- but a command override
# for THIS script (see usage above) is naturally written with one
# (`./shell.sh -- ttyd ...`), so strip a single leading "--" here instead.
[[ "${1:-}" == "--" ]] && shift

# Same pull-then-build-fallback marimo.sh already uses (see lib.sh's
# apptainer_resolve_image), not just a bare local build -- without this,
# every FIRST-EVER shell.sh invocation on a given node (e.g. the first
# terminal-https job to land there) pays a multi-minute from-scratch build
# (apt-get, pixi install, 5 npm installs, the Antigravity CLI download,
# then SIF creation) instead of a fast registry pull. Confirmed live: this
# was the root cause of a real Fileglancer terminal-https job showing a
# confusing 502 for several minutes -- terminal-wrap.sh's Caddy only waits
# 30s for the backend before starting anyway, so a multi-minute cold build
# meant several minutes of 502s that a fast pull would have avoided
# entirely. Also re-checks the registry on every run (not just when
# nothing is cached yet) -- confirmed live for the identical Podman bug
# this mirrors: a stale .sif cached from before ttyd was added to
# pixi.toml was otherwise reused forever, since the old check never
# re-validated a cache hit.
apptainer_resolve_image "$REMOTE_IMAGE" "$_SIF_EXPLICIT"

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

# Any trailing args (after --allow/--ro-paths/--work are consumed by
# common.sh above) name a command to run instead of an interactive shell --
# e.g. `./shell.sh -- ttyd -p 7681 -W bash` for container/terminal-wrap.sh.
COMMON_ARGS=(
    --contain
    --cleanenv
    --pid
    --home "$WORK/home:/work/home"
    --env TMPDIR=/work/tmp
    "${BIND_ARGS[@]}"
    "${ENV_ARGS[@]}"
    "${GPU_ARGS[@]}"
    --pwd /work
)

if [[ ${#APPTAINER_EXEC_WRAP[@]} -gt 0 ]]; then
    # Egress allowlist active: start the in-container relay (and export
    # http_proxy/https_proxy) before running the override command (or an
    # interactive shell if none was given). `apptainer shell` has no hook
    # for this, so use `apptainer exec .../bin/bash` instead -- not exec'd
    # here (unlike the branches below), so the EXIT trap above can stop the
    # host-side proxy once the command exits.
    [[ $# -eq 0 ]] && set -- bash
    apptainer exec \
        "${COMMON_ARGS[@]}" \
        "${APPTAINER_NET_ARGS[@]}" \
        "${APPTAINER_BIND_EXTRA[@]}" \
        "$SIF" /bin/bash "${APPTAINER_EXEC_WRAP[@]}" "$@"
    exit $?
elif [[ $# -gt 0 ]]; then
    exec apptainer exec "${COMMON_ARGS[@]}" "$SIF" "$@"
fi

exec apptainer shell "${COMMON_ARGS[@]}" "$SIF"
