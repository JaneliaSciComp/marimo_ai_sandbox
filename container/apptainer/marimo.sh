#!/usr/bin/env bash
#
# marimo.sh -- launch the Marimo sandbox with a read-only view of the host
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
# --cleanenv: unlike Podman/Docker, Apptainer's default is to inherit the
# ENTIRE calling shell's environment, not just what's explicitly passed via
# --env/--home -- silently bypassing common.sh's ENV_PAIRS allowlist
# (verified: an arbitrary host env var leaks straight into an `apptainer
# exec` with no --cleanenv, but not into the equivalent `podman run`).
# --cleanenv makes this backend's behavior match Podman's: only ENV_PAIRS
# (plus HOME/TMPDIR, set explicitly below) reaches the container.
#
# --pid: unlike Podman (which isolates the PID namespace by default -- no
# change needed there), Apptainer's default is to SHARE the host PID
# namespace, so `ps aux` inside the container shows every process on the
# compute node, not just this job's. --pid gives it its own namespace
# (verified unprivileged: `ps aux` inside then shows only the container's
# own ~2 processes). Podman's own cgroup/CPU/memory limit flags
# (--memory/--cpus/--pids-limit) and Apptainer's equivalents are NOT used
# here despite being available: Apptainer's hard-fail ("cannot use cgroups
# - 'systemd cgroups' is not enabled in apptainer.conf") and Podman's
# silent no-op (accepts --memory, does not enforce it) under this host's
# rootless/cgroupfs-manager setup make both unreliable without an
# apptainer.conf/cgroup-v2-delegation change only Janelia IT can make. The
# `resources:` block in runnables.yaml (cpus/memory/walltime) is the real
# resource control today, enforced by LSF at the job level instead.
#
# Image source: by default this checks the registry for updates to the OCI
# image published by .github/workflows/publish-image.yml
# (ghcr.io/janeliascicomp/marimo_ai_sandbox) on EVERY run, converting it
# into a local .sif -- apptainer reuses its own OCI blob cache for
# unchanged layers, so an unchanged check is far cheaper than a full
# `apptainer build --fakeroot` from source (which reinstalls pixi/npm/
# Antigravity from scratch every time). If the pull fails (offline compute
# node, registry unreachable), it reuses whatever .sif is already cached
# locally if any is, and only builds marimo_sandbox.sif locally via
# build.sh as a last resort. Always checking, rather than only pulling the
# first time, avoids silently reusing a stale .sif forever once one
# happens to be cached (confirmed live: a locally-cached .sif from before
# a pixi.toml dependency change went undetected until this fix). Set SIF
# to point at an existing local .sif to skip the registry entirely and
# always build locally on first use -- an explicit override like this is
# trusted as-is, never re-checked.
#
# Usage:
#   ./marimo.sh                                  # serve Marimo on :8080
#   RO_PATHS="/groups/scicompsoft /nrs/scicompsoft" ./marimo.sh
#   ./marimo.sh --ro-paths "/groups/scicompsoft /nrs/scicompsoft"
#   WORK=/scratch/$USER/work ./marimo.sh
#   ./marimo.sh --work /scratch/$USER/work
#   PORT=9000 ./marimo.sh
#   ./marimo.sh --port 9000
#   ./marimo.sh --allow litellm.int.janelia.org    # restrict egress to just this host
#   ./marimo.sh --extra-marimo-flag                 # unrecognized args go to marimo
set -euo pipefail

# Captured before the cd below so common.sh can resolve a relative --work
# path against where the user actually ran this from, not this script's dir.
_CALLER_PWD="$PWD"

cd "$(dirname "$0")"

_SIF_EXPLICIT=0; [[ -n "${SIF:-}" ]] && _SIF_EXPLICIT=1
SIF="${SIF:-marimo_sandbox.sif}"
REMOTE_IMAGE="${REMOTE_IMAGE:-docker://ghcr.io/janeliascicomp/marimo_ai_sandbox:latest}"

# Reports coarse progress to Fileglancer's phase file (set only when this
# runs as a Fileglancer job -- see https-wrap.sh, which does the same), so
# the UI can show "pulling image"/"starting" instead of looking hung during
# a slow first-time pull. A no-op everywhere else.
_set_phase() {
    [[ -n "${FG_PHASE_PATH:-}" ]] && printf '%s' "$1" > "$FG_PHASE_PATH" 2>/dev/null
    return 0
}

# shellcheck source=common.sh
source "../common.sh"
# shellcheck source=lib.sh
source "./lib.sh"

apptainer_resolve_image "$REMOTE_IMAGE" "$_SIF_EXPLICIT"

BIND_ARGS=(); for p in "${BIND_PAIRS[@]}"; do BIND_ARGS+=(--bind "$p"); done
ENV_ARGS=();  for e in "${ENV_PAIRS[@]}"; do  ENV_ARGS+=(--env "$e"); done
GPU_ARGS=();  [[ "$HAS_GPU" == "1" ]] && GPU_ARGS+=(--nv)

# Off by default (unrestricted, shared host network): see lib.sh's
# apptainer_network_setup.
apptainer_network_setup
trap apptainer_network_cleanup EXIT

# See common.sh's write_bsub_runner_apptainer and container/bsub-wrapper/
# bin/bsub: when enabled, a wrapped `bsub ... -- <cmd>` re-enters this exact
# sandbox on whatever node LSF schedules it to.
[[ "$ENABLE_BSUB" == "1" ]] && write_bsub_runner_apptainer "$SIF"

echo ">> Serving Marimo on http://0.0.0.0:${PORT}  (work dir: $WORK)"
echo ">> Read-only host binds:${RO_PATHS:- (none)}"
[[ "$HAS_GPU" == "1" ]] && echo ">> GPU detected -- passing --nv"
[[ -n "${ALLOW_HOSTS// /}" ]] && echo ">> Egress allowlist active: $ALLOW_HOSTS (unrestricted otherwise); proxy log: $APPTAINER_PROXY_DIR/proxy.log"
_set_phase starting

if [[ ${#APPTAINER_EXEC_WRAP[@]} -gt 0 ]]; then
    # Egress allowlist active: Apptainer has no ENTRYPOINT to override the
    # way Podman does, so switch from `apptainer run` (which execs the
    # image's baked %runscript, /opt/app/entrypoint.sh) to `apptainer exec`
    # naming that same script explicitly, wrapped so the relay starts (and
    # http_proxy/https_proxy get set) first. Not exec'd here (unlike the
    # default branch below): the script needs to run back in the foreground
    # so the EXIT trap above can stop the host-side proxy afterward.
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
        "$SIF" /bin/bash "${APPTAINER_EXEC_WRAP[@]}" /opt/app/entrypoint.sh --port "$PORT" "$@"
    exit $?
fi

exec apptainer run \
    --contain \
    --cleanenv \
    --pid \
    --home "$WORK/home:/work/home" \
    --env TMPDIR=/work/tmp \
    "${BIND_ARGS[@]}" \
    "${ENV_ARGS[@]}" \
    "${GPU_ARGS[@]}" \
    "$SIF" --port "$PORT" "$@"
