#!/usr/bin/env bash
#
# lib.sh -- Podman-specific hardening helpers, sourced by
# container/podman/{build,marimo,shell}.sh (not by common.sh -- build.sh
# doesn't need common.sh's WORK/RO_PATHS/GPU-detection machinery, just these
# storage/network functions). Not meant to be executed directly.
#
# Adapted from JaneliaScientificComputingSystems/agentic-sandbox's
# scripts/podman-run.sh, which battle-tested storage isolation, staleness
# recovery, and the catatonit watchdog below on this same Janelia LSF
# cluster for a related (untrusted-agent-code) sandboxing use case. The
# network allowlist itself (allowlist_proxy.py/relay.py, vendored at
# container/, shared with the Apptainer backend) is adapted from the same
# repo's bwrap-side mechanism; see ../common.sh's network_allowlist_* for
# the backend-agnostic parts.

# _podman_storage_shared_setup -- redirects Podman storage off NFS
# (~/.local/share/containers, this host's default, doesn't support
# lsetxattr) to /scratch/$USER/podman-storage, and reconciles staleness
# (e.g. after a node reboot) before anything else runs -- the same fix
# Janelia's own Harbor/LSF fork and agentic-sandbox both apply on this
# cluster. This is the SHARED, durable store: `podman pull`/`image
# exists`/`build` (with no --root/--runroot override) resolve here via
# CONTAINERS_STORAGE_CONF.
#
# Sets:   PODMAN_STORAGE_ROOT, PODMAN_RUN_ROOT, PODMAN_STORAGE_CONF_FILE
# Exports: CONTAINERS_STORAGE_CONF
_podman_storage_shared_setup() {
    if [[ -z "${XDG_RUNTIME_DIR:-}" ]] || [[ ! -d "$XDG_RUNTIME_DIR" ]]; then
        export XDG_RUNTIME_DIR="/tmp/podman-run-$(id -u)"
        mkdir -p "$XDG_RUNTIME_DIR"
        chmod 700 "$XDG_RUNTIME_DIR"
    fi

    PODMAN_STORAGE_ROOT="${PODMAN_STORAGE_ROOT:-/scratch/$(id -un)/podman-storage}"
    PODMAN_RUN_ROOT="${PODMAN_RUN_ROOT:-/tmp/podman-run-$(id -u)/run}"
    mkdir -p "$PODMAN_STORAGE_ROOT" "$PODMAN_RUN_ROOT"

    PODMAN_STORAGE_CONF_FILE="$(mktemp /tmp/podman-storage-XXXXXX.conf)"
    cat > "$PODMAN_STORAGE_CONF_FILE" <<EOF
[storage]
driver = "overlay"
graphRoot = "$PODMAN_STORAGE_ROOT"
runRoot  = "$PODMAN_RUN_ROOT"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
ignore_chown_errors = "true"
EOF
    export CONTAINERS_STORAGE_CONF="$PODMAN_STORAGE_CONF_FILE"

    podman system migrate 2>/dev/null || true
    podman info >/dev/null 2>&1 || podman system reset -f
}

# podman_storage_setup -- for callers (build.sh) that only need the shared
# store above, no per-job isolation (a build only needs to land in the
# durable shared cache; it isn't a concurrency-hot-path the way running
# containers is).
podman_storage_setup() {
    _podman_storage_shared_setup
}

# podman_storage_setup_job -- for callers (marimo.sh/shell.sh) that actually
# run a container. Adds an ISOLATED --root/--runroot for THIS invocation,
# keyed by $LSB_JOBID -- without this, two concurrent Podman jobs from the
# same user landing on the same GPU node can corrupt each other's storage
# (the real, verified failure mode agentic-sandbox's ADMIN-NOTES documents;
# this repo's own Podman scripts had no such isolation before this change).
# --storage-opt additionalimagestore points the per-job store back at the
# shared graphRoot as a READ-ONLY layer source, so a second job on the SAME
# node reuses the already-pulled/built image instead of paying for it again.
#
# Sets: PODMAN_GLOBAL_ARGS (array; prefix `podman build`/`podman run` with
#       this to use the per-job isolated store), PODMAN_JOB_STORAGE_DIR (the
#       dir podman_storage_cleanup removes).
podman_storage_setup_job() {
    _podman_storage_shared_setup

    local jobtag="${LSB_JOBID:-$$-$RANDOM}"
    PODMAN_JOB_STORAGE_DIR="/scratch/$(id -un)/podman-jobs/$jobtag"
    mkdir -p "$PODMAN_JOB_STORAGE_DIR/root" "$PODMAN_JOB_STORAGE_DIR/run"
    PODMAN_GLOBAL_ARGS=(
        --root "$PODMAN_JOB_STORAGE_DIR/root"
        --runroot "$PODMAN_JOB_STORAGE_DIR/run"
        --storage-opt "overlay.mount_program=/usr/bin/fuse-overlayfs"
        --storage-opt "overlay.ignore_chown_errors=true"
        --storage-opt "additionalimagestore=$PODMAN_STORAGE_ROOT"
    )
}

# podman_storage_cleanup -- retry-loop removal of a per-job storage dir.
#
# Uses `podman unshare rm -rf`, not a plain `rm -rf` -- confirmed live for
# an account with no requested /etc/subuid/subgid range (the default on
# this cluster; see README's "Podman Build" prerequisite note -- see also
# _podman_storage_shared_setup's ignore_chown_errors=true and the
# Containerfile's TAR_OPTIONS=--no-same-owner, both existing workarounds
# for the same constraint): overlay diff-layer files land owned by a fake
# UID inside Podman's own single-mapping user namespace that only `podman
# unshare` can remove -- a real user's plain `rm -rf` hits "Permission
# denied" on every file, every time, not just an occasional busy-mount
# race. (agentic-sandbox's own cluster requires a subuid range as a
# prerequisite for every account -- its README lists that as a
# prerequisite -- so its plain `rm -rf` retry loop didn't need this.
# `podman unshare rm -rf` is expected to keep working for an account here
# that has requested a range too, just not verified live yet for that
# combination.)
#
# Retries for up to 30s in case the overlay unmount for a just-removed
# (--rm) container isn't finished the instant `podman run` returns. Leaving
# it (logged, not fatal) is cheap: only lock/metadata files, no image data
# (that lives in the shared additionalimagestore), and /scratch cleans
# itself up on its own cycle regardless.
podman_storage_cleanup() {
    local dir="${1:-${PODMAN_JOB_STORAGE_DIR:-}}"
    [[ -z "$dir" ]] && return 0
    for _ in $(seq 1 30); do
        podman unshare rm -rf "$dir" 2>/dev/null && return 0
        sleep 1
    done
    [[ -e "$dir" ]] && echo "note: couldn't clean up $dir (still busy after 30s) -- safe to remove later" >&2
    return 0
}

# _podman_kill_orphaned_catatonit -- kill any catatonit (Podman's tiny
# container-init) belonging to THIS job specifically that has been
# reparented to PID 1 (i.e. actually orphaned, not just a sibling job's
# still-healthy one, and not our own container's still-running one -- both
# conditions, PPID==1 AND referencing our own job's storage path, must hold
# together; agentic-sandbox's ADMIN-NOTES documents hitting a real bug from
# checking only one). catatonit occasionally isn't reaped by Podman's own
# monitor before being reparented, which then blocks `podman run` itself
# from ever returning -- a known, independently-confirmed issue on this
# exact cluster (Janelia's own Harbor/LSF fork hits the same thing).
_podman_kill_orphaned_catatonit() {
    local job_dir="$1" pid
    [[ -z "$job_dir" ]] && return 0
    for pid in $(pgrep -u "$USER" -x catatonit 2>/dev/null); do
        [[ "$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')" == "1" ]] || continue
        grep -q "$job_dir" "/proc/$pid/mountinfo" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    done
    return 0
}

# podman_run_watched -- run `podman run` (prefixed with PODMAN_GLOBAL_ARGS)
# in the background with a concurrent catatonit watchdog, then wait and
# return its real exit code.
#
# Usage: podman_run_watched ARGS_ARRAY_NAME
#   ARGS_ARRAY_NAME names an array variable holding the full argument list
#   for `podman run` (everything after "run" itself).
#
# Requires the caller to have already run `exec 3<&0` at the very top of its
# own script (before any other redirection/backgrounding) -- bash silently
# redirects a backgrounded job's stdin from /dev/null otherwise, which would
# break piped input and interactive sessions alike. `podman run` has to run
# backgrounded here for the watchdog subshell to run alongside it (Podman
# itself can be blocked waiting on an orphaned catatonit, so a cleanup trap
# that only runs once `podman run` returns would never get a chance to
# fire).
#
# Returns the real exit code of `podman run` (does not exit the shell --
# caller does `podman_run_watched ARGS_VAR; exit $?`).
podman_run_watched() {
    local -n _args_ref="$1"
    local job_dir="${PODMAN_JOB_STORAGE_DIR:-}"

    podman "${PODMAN_GLOBAL_ARGS[@]}" run "${_args_ref[@]}" <&3 &
    local podman_pid=$!

    (
        while kill -0 "$podman_pid" 2>/dev/null; do
            _podman_kill_orphaned_catatonit "$job_dir"
            sleep 2
        done
    ) &
    local watchdog_pid=$!

    local exit_code=0
    wait "$podman_pid" || exit_code=$?
    kill "$watchdog_pid" 2>/dev/null
    wait "$watchdog_pid" 2>/dev/null || true
    _podman_kill_orphaned_catatonit "$job_dir"
    return "$exit_code"
}

# podman_network_setup -- opt-in Podman egress allowlist. Off by default:
# this repo's Podman scripts keep their existing unrestricted --net=host
# unless $ALLOW_HOSTS is set (via --allow, repeatable). Thin Podman-specific
# wrapper around common.sh's backend-agnostic
# network_allowlist_proxy_start/network_allowlist_inner_wrap -- see
# container/apptainer/lib.sh for the Apptainer equivalent.
#
# Sets:
#   PODMAN_NETWORK_ARGS    -- array: --net=host (default), or --network=none
#                             plus the relay/proxy-socket volume mounts
#   PODMAN_PROXY_PID       -- host-side allowlist_proxy.py PID, or "" if unused
#   PODMAN_PROXY_SOCK      -- its Unix socket path, or "" if unused
#   PODMAN_PROXY_DIR       -- the private temp dir PODMAN_PROXY_SOCK lives in
#                             (removed wholesale by podman_network_cleanup),
#                             or "" if unused
#   PODMAN_INNER_ENTRYPOINT -- "/bin/bash" if the allowlist is active (the
#                             caller must add `--entrypoint
#                             "$PODMAN_INNER_ENTRYPOINT"` when non-empty),
#                             else ""
#   PODMAN_INNER_ARGS      -- array; when non-empty, append it (then the
#                             real command) as the podman run "command"
#                             positional args -- starts the in-container
#                             relay and exports http_proxy/https_proxy
#                             before exec'ing through to the real command
podman_network_setup() {
    PODMAN_INNER_ENTRYPOINT=""
    PODMAN_INNER_ARGS=()

    network_allowlist_proxy_start
    PODMAN_PROXY_PID="$NETWORK_PROXY_PID"
    PODMAN_PROXY_SOCK="$NETWORK_PROXY_SOCK"
    PODMAN_PROXY_DIR="$NETWORK_PROXY_DIR"

    if [[ -z "${ALLOW_HOSTS// /}" ]]; then
        PODMAN_NETWORK_ARGS=(--net=host)
        return 0
    fi

    PODMAN_NETWORK_ARGS=(
        --network=none
        -v "$NETWORK_SCRIPTS_DIR/relay.py:/opt/relay.py:ro"
        -v "$PODMAN_PROXY_SOCK:/run/proxy.sock:ro"
    )
    PODMAN_INNER_ENTRYPOINT="/bin/bash"
    network_allowlist_inner_wrap
    PODMAN_INNER_ARGS=("${NETWORK_INNER_WRAP[@]}")
}

# podman_network_cleanup -- stop the host-side allowlist proxy (if any) and
# remove its socket. No-op when the allowlist was never enabled.
podman_network_cleanup() {
    network_allowlist_proxy_cleanup
}

# podman_resolve_image -- resolves $IMAGE to something runnable, shared by
# marimo.sh and shell.sh.
#
# Unless the caller explicitly set $IMAGE (env var or otherwise), this
# checks the registry for updates on EVERY invocation via `podman pull`
# (cheap -- a manifest-digest check, not a re-download, unless the image
# actually changed) rather than the old "only pull if nothing is cached at
# all" check, which -- confirmed live -- silently reused a local image
# cached from before a pixi.toml dependency change (ttyd) forever, since
# nothing ever re-validated it once it existed once.
#
# Usage: podman_resolve_image REMOTE_IMAGE LOCAL_IMAGE IMAGE_WAS_EXPLICIT
#   REMOTE_IMAGE       the ghcr.io reference to check/pull
#   LOCAL_IMAGE        the local-build fallback tag
#   IMAGE_WAS_EXPLICIT "1" if the caller's $IMAGE was set by the user
#                      (env var or --image-style override) rather than
#                      defaulted -- skips the registry entirely in that
#                      case, building only if that exact image is missing
#                      (the existing "IMAGE=marimo_sandbox:latest ...to
#                      skip the registry" escape hatch, preserved as-is)
#
# Requires the caller to already have a `_set_phase` function defined
# (both marimo.sh and shell.sh do) -- reports "pulling_image" through it
# the same way the caller's other phases are reported.
#
# Sets: RESOLVED_IMAGE -- the image reference the caller should actually run
podman_resolve_image() {
    local remote="$1" local_image="$2" explicit="$3"
    RESOLVED_IMAGE="$remote"

    if [[ "$explicit" == "1" ]]; then
        podman image exists "$RESOLVED_IMAGE" &>/dev/null || bash ./build.sh
        return 0
    fi

    echo ">> Checking '$RESOLVED_IMAGE' for updates ..."
    _set_phase pulling_image
    if ! podman pull "$RESOLVED_IMAGE"; then
        if podman image exists "$RESOLVED_IMAGE" &>/dev/null; then
            echo ">> Pull failed (offline/registry unreachable?) -- reusing existing cached '$RESOLVED_IMAGE'." >&2
        else
            echo ">> Pull failed and no local copy exists -- building '$local_image' from source instead ..." >&2
            RESOLVED_IMAGE="$local_image"
            podman image exists "$RESOLVED_IMAGE" &>/dev/null || bash ./build.sh
        fi
    fi
}
