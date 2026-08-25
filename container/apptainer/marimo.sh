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
# Image source: by default this pulls (and converts) the OCI image published
# by .github/workflows/publish-image.yml
# (ghcr.io/janeliascicomp/marimo_ai_sandbox) into a local .sif, instead of
# building from source with `apptainer build --fakeroot` (slow -- no layer
# cache, reinstalls pixi/npm/Antigravity from scratch every time). If the
# pull fails (offline compute node, registry unreachable) and no local .sif
# exists yet, it falls back to building marimo_sandbox.sif locally via
# build.sh. Set SIF to point at an existing local .sif to skip the registry
# entirely.
#
# Usage:
#   ./start.sh                                  # serve Marimo on :8080
#   RO_PATHS="/groups/scicompsoft /nrs/scicompsoft" ./start.sh
#   ./start.sh --ro-paths "/groups/scicompsoft /nrs/scicompsoft"
#   WORK=/scratch/$USER/work ./start.sh
#   ./start.sh --work /scratch/$USER/work
#   PORT=9000 ./start.sh
#   ./start.sh --port 9000
#   ./start.sh --extra-marimo-flag                 # unrecognized args go to marimo
set -euo pipefail

cd "$(dirname "$0")"

SIF="${SIF:-marimo_sandbox.sif}"
REMOTE_IMAGE="${REMOTE_IMAGE:-docker://ghcr.io/janeliascicomp/marimo_ai_sandbox:latest}"

if [[ ! -f "$SIF" ]]; then
    echo ">> Image '$SIF' not found -- pulling from registry ..."
    TMP_SIF="${SIF}.tmp.$$"
    trap 'rm -f "$TMP_SIF"' EXIT
    if apptainer pull "$TMP_SIF" "$REMOTE_IMAGE"; then
        mv "$TMP_SIF" "$SIF"
        trap - EXIT
    else
        rm -f "$TMP_SIF"
        trap - EXIT
        echo ">> Pull failed -- building '$SIF' from source instead ..." >&2
        bash ./build.sh
    fi
fi

# shellcheck source=common.sh
source "../common.sh"

BIND_ARGS=(); for p in "${BIND_PAIRS[@]}"; do BIND_ARGS+=(--bind "$p"); done
ENV_ARGS=();  for e in "${ENV_PAIRS[@]}"; do  ENV_ARGS+=(--env "$e"); done

echo ">> Serving Marimo on http://0.0.0.0:${PORT}  (work dir: $WORK)"
echo ">> Read-only host binds:${RO_PATHS:- (none)}"
exec apptainer run \
    --contain \
    --cleanenv \
    --pid \
    --home "$WORK/home:/work/home" \
    --env TMPDIR=/work/tmp \
    "${BIND_ARGS[@]}" \
    "${ENV_ARGS[@]}" \
    "$SIF" --port "$PORT" "$@"
