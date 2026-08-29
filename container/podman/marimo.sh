#!/usr/bin/env bash
#
# marimo.sh -- launch the Marimo sandbox via Podman with a read-only view
# of the host filesystem and a single writable work directory.
#
# See ../apptainer/marimo.sh for the read-only model and the autofs/NFS caveat.
# See ../common.sh for WORK/PORT/RO_PATHS/ALLOW_HOSTS defaults, bind, and env
# setup, and ./lib.sh for the Podman storage/watchdog/network-allowlist
# helpers used below.
#
# Janelia HPC notes:
#   --cgroup-manager=cgroupfs  no systemd user session on compute nodes
#   --events-backend=file      no dbus session available
#   --userns=keep-id omitted   requires an /etc/subuid range; not requested by
#                              default for any account on this cluster (see
#                              README's "Podman Build" prerequisite note)
#   Storage redirected to /scratch to avoid NFS xattr failures, with a
#   per-job isolated --root/--runroot so concurrent Podman jobs from the
#   same user on the same GPU node don't corrupt each other's storage
#   (see lib.sh's podman_storage_setup_job).
#
# Image source: by default this checks the registry for updates to the
# image published by .github/workflows/publish-image.yml
# (ghcr.io/janeliascicomp/marimo_ai_sandbox) on EVERY run -- a cheap
# manifest-digest check, not a re-download, unless the image actually
# changed -- instead of building from source. If the pull fails (offline
# compute node, registry unreachable), it reuses whatever's already cached
# locally if anything is, and only builds marimo_sandbox:latest locally
# via build.sh as a last resort (no cache, no registry reachable). Always
# checking, rather than only pulling the first time, avoids silently
# reusing a stale image forever once one happens to be cached (confirmed
# live: a locally-cached image from before a pixi.toml dependency change
# went undetected until this fix). Set IMAGE to any other reference to
# pull that instead, or to a purely local tag (e.g. marimo_sandbox:latest)
# to skip the registry entirely and always build locally on first use --
# an explicit override like this is trusted as-is, never re-checked.
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
#   ./marimo.sh --extra-marimo-flag              # unrecognized args go to marimo
#   IMAGE=marimo_sandbox:latest ./marimo.sh       # skip the registry, build locally
set -euo pipefail

# Save the real stdin before podman run backgrounds (needed for lib.sh's
# podman_run_watched catatonit watchdog) -- bash silently redirects a
# backgrounded job's stdin from /dev/null otherwise, breaking piped input.
exec 3<&0

# Captured before the cd below so common.sh can resolve a relative --work
# path against where the user actually ran this from, not this script's dir.
_CALLER_PWD="$PWD"

cd "$(dirname "$0")"

_IMAGE_EXPLICIT=0; [[ -n "${IMAGE:-}" ]] && _IMAGE_EXPLICIT=1
IMAGE="${IMAGE:-ghcr.io/janeliascicomp/marimo_ai_sandbox:latest}"
LOCAL_IMAGE="marimo_sandbox:latest"

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

# Reports coarse progress to Fileglancer's phase file (set only when this
# runs as a Fileglancer job -- see https-wrap.sh, which does the same), so
# the UI can show "pulling image"/"starting" instead of looking hung during
# a slow first-time pull. A no-op everywhere else.
_set_phase() {
    [[ -n "${FG_PHASE_PATH:-}" ]] && printf '%s' "$1" > "$FG_PHASE_PATH" 2>/dev/null
    return 0
}

podman_resolve_image "$IMAGE" "$LOCAL_IMAGE" "$_IMAGE_EXPLICIT"
IMAGE="$RESOLVED_IMAGE"

BIND_ARGS=(); for p in "${BIND_PAIRS[@]}"; do BIND_ARGS+=(-v "$p"); done
ENV_ARGS=();  for e in "${ENV_PAIRS[@]}"; do  ENV_ARGS+=(-e "$e"); done
# --device nvidia.com/gpu=all: CDI (Container Device Interface), not the
# older --gpus flag -- this host's GPU access is provisioned via
# nvidia-container-toolkit's CDI spec (/etc/cdi/nvidia.yaml), which rootless
# Podman supports directly with no extra runtime flags needed.
GPU_ARGS=();  [[ "$HAS_GPU" == "1" ]] && GPU_ARGS+=(--device nvidia.com/gpu=all)

# Off by default (--net=host, unchanged): see lib.sh's podman_network_setup.
podman_network_setup

# See common.sh's write_bsub_runner_podman and container/bsub-wrapper/bin/
# bsub: when enabled, a wrapped `bsub ... -- <cmd>` re-enters this exact
# sandbox on whatever node LSF schedules it to.
[[ "$ENABLE_BSUB" == "1" ]] && write_bsub_runner_podman "$IMAGE"

echo ">> Serving Marimo on http://0.0.0.0:${PORT}  (work dir: $WORK)"
echo ">> Read-only host binds:${RO_PATHS:- (none)}"
[[ "$HAS_GPU" == "1" ]] && echo ">> GPU detected -- passing --device nvidia.com/gpu=all"
[[ -n "${ALLOW_HOSTS// /}" ]] && echo ">> Egress allowlist active: $ALLOW_HOSTS (--network=none otherwise); proxy log: $PODMAN_PROXY_DIR/proxy.log"
_set_phase starting

PODMAN_RUN_ARGS=(
    --rm -it
    --read-only
    --tmpfs /tmp
    --tmpfs /run
    --cgroup-manager=cgroupfs
    --events-backend=file
    "${PODMAN_NETWORK_ARGS[@]}"
    -e HOME=/work/home
    -e TMPDIR=/work/tmp
    -w /work
    "${BIND_ARGS[@]}"
    "${ENV_ARGS[@]}"
    "${GPU_ARGS[@]}"
)
# Egress allowlist active: override the image's baked ENTRYPOINT so the
# in-container relay starts (and http_proxy/https_proxy get set) before the
# real entrypoint runs -- otherwise the image's own /opt/app/entrypoint.sh
# would start with no proxy in place yet.
if [[ -n "$PODMAN_INNER_ENTRYPOINT" ]]; then
    PODMAN_RUN_ARGS=(--entrypoint "$PODMAN_INNER_ENTRYPOINT" "${PODMAN_RUN_ARGS[@]}")
    PODMAN_RUN_ARGS+=("$IMAGE" "${PODMAN_INNER_ARGS[@]}" /opt/app/entrypoint.sh --port "$PORT" "$@")
else
    PODMAN_RUN_ARGS+=("$IMAGE" --port "$PORT" "$@")
fi

podman_run_watched PODMAN_RUN_ARGS
exit $?
