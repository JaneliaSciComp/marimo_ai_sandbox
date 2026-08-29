#!/usr/bin/env bash
#
# lib.sh -- Apptainer-specific network-allowlist helper, sourced by
# container/apptainer/{marimo,shell}.sh. Not meant to be executed directly.
#
# Thin Apptainer-specific wrapper around common.sh's backend-agnostic
# network_allowlist_proxy_start/network_allowlist_inner_wrap -- see
# container/podman/lib.sh for the Podman equivalent. Apptainer doesn't need
# that file's storage-isolation/catatonit-watchdog hardening: it's not a
# daemon-backed runtime, so there's no shared storage state for concurrent
# jobs to corrupt, and no orphan-process reaping issue -- `apptainer
# exec`/`run`/`shell` runs directly as this script's own child, no separate
# container-init process to leak.

# apptainer_network_setup -- opt-in Apptainer egress allowlist (same
# ALLOW_HOSTS/--allow as Podman's). Off by default: Apptainer scripts keep
# their existing unrestricted (shared host network) behavior unless
# $ALLOW_HOSTS is set.
#
# Confirmed live on this cluster: `apptainer exec --net --network none ...`
# gives the same isolated-loopback-only network Podman's --network=none
# does (no bridge/NAT set up, since this host's unprivileged Apptainer
# install has no setuid/fakeroot network plugin configured) -- exactly what
# the relay/proxy trick needs.
#
# Sets:
#   APPTAINER_NET_ARGS   -- array: () (default, unrestricted) or
#                           (--net --network none)
#   APPTAINER_BIND_EXTRA -- array: extra --bind flags for the relay script
#                           + proxy socket, empty if unused
#   APPTAINER_PROXY_PID/APPTAINER_PROXY_SOCK/APPTAINER_PROXY_DIR -- see
#                           common.sh's network_allowlist_proxy_start
#   APPTAINER_EXEC_WRAP  -- array; when non-empty, the caller must run
#                           `apptainer exec ... "$SIF" /bin/bash
#                           "${APPTAINER_EXEC_WRAP[@]}" <real cmd...>`
#                           instead of its normal `apptainer run`/`shell`
#                           invocation -- Apptainer has no ENTRYPOINT to
#                           override the way Podman does, so switching to a
#                           bare `exec` with an explicit command is how the
#                           relay gets started before the real command runs.
apptainer_network_setup() {
    APPTAINER_EXEC_WRAP=()

    network_allowlist_proxy_start
    APPTAINER_PROXY_PID="$NETWORK_PROXY_PID"
    APPTAINER_PROXY_SOCK="$NETWORK_PROXY_SOCK"
    APPTAINER_PROXY_DIR="$NETWORK_PROXY_DIR"

    if [[ -z "${ALLOW_HOSTS// /}" ]]; then
        APPTAINER_NET_ARGS=()
        APPTAINER_BIND_EXTRA=()
        return 0
    fi

    APPTAINER_NET_ARGS=(--net --network none)
    APPTAINER_BIND_EXTRA=(
        --bind "$NETWORK_SCRIPTS_DIR/relay.py:/opt/relay.py:ro"
        --bind "$APPTAINER_PROXY_SOCK:/run/proxy.sock:ro"
    )
    network_allowlist_inner_wrap
    APPTAINER_EXEC_WRAP=("${NETWORK_INNER_WRAP[@]}")
}

# apptainer_network_cleanup -- stop the host-side allowlist proxy (if any)
# and remove its socket. No-op when the allowlist was never enabled.
apptainer_network_cleanup() {
    network_allowlist_proxy_cleanup
}

# apptainer_resolve_image -- resolves $SIF to something runnable, shared by
# marimo.sh and shell.sh. Mirrors ../podman/lib.sh's podman_resolve_image.
#
# Unless the caller explicitly pointed $SIF at something (e.g. `SIF=foo.sif
# ./marimo.sh`), this checks the registry for updates on EVERY invocation
# via `apptainer pull` (apptainer reuses its own OCI blob cache for
# unchanged layers, so an unchanged check is far cheaper than it looks --
# "Using cached SIF image", not a full re-download) rather than the old
# "only pull if the file doesn't exist at all" check, which -- confirmed
# live for the identical Podman bug this mirrors -- would silently reuse a
# local .sif cached from before a pixi.toml dependency change forever,
# since nothing ever re-validated it once it existed once.
#
# Usage: apptainer_resolve_image REMOTE_IMAGE SIF_WAS_EXPLICIT
#   REMOTE_IMAGE     the docker://... reference to check/pull
#   SIF_WAS_EXPLICIT "1" if the caller's $SIF was set by the user (env var
#                    or otherwise) rather than defaulted -- skips the
#                    registry entirely in that case, building only if that
#                    exact file is missing (the existing "SIF=foo.sif ...
#                    to skip the registry" escape hatch, preserved as-is)
#
# Requires the caller to already have a `_set_phase` function defined and
# its own $SIF variable set -- reads/writes $SIF directly.
apptainer_resolve_image() {
    local remote="$1" explicit="$2"

    if [[ "$explicit" == "1" ]]; then
        [[ -f "$SIF" ]] || bash ./build.sh
        return 0
    fi

    echo ">> Checking '$remote' for updates ..."
    _set_phase pulling_image
    local tmp_sif="${SIF}.tmp.$$"
    trap 'rm -f "$tmp_sif"' EXIT
    if apptainer pull "$tmp_sif" "$remote"; then
        mv "$tmp_sif" "$SIF"
        trap - EXIT
    else
        rm -f "$tmp_sif"
        trap - EXIT
        if [[ -f "$SIF" ]]; then
            echo ">> Pull failed (offline/registry unreachable?) -- reusing existing local '$SIF'." >&2
        else
            echo ">> Pull failed and no local '$SIF' exists -- building from source instead ..." >&2
            bash ./build.sh
        fi
    fi
}
