#!/usr/bin/env bash
#
# terminal-wrap.sh -- front a web terminal (ttyd, run INSIDE the sandbox via
# container/{apptainer,podman}/shell.sh's command-override support) with a
# Caddy TLS-terminating reverse proxy -- the same one container/https-wrap.sh
# uses for Marimo. See container/caddy-lib.sh for the shared cert/Caddy/
# service-URL machinery both wrappers use.
#
# ttyd itself has no TLS support either (like Marimo), so this wrapper is
# the HTTPS layer. Auth is ttyd's own HTTP Basic Auth (-c user:pass), using
# the same token-resolution idiom as https-wrap.sh's Marimo token (prefer
# FG_SERVICE_TOKEN, else a random token persisted per work dir) but kept in
# its own file (.terminal-token) so the two services don't share credentials
# even if both are pointed at the same --work dir at once. The token is
# embedded directly in the launch URL's userinfo
# (https://user:token@host:port/), which browsers use to auto-authenticate
# the same way Marimo's ?access_token= query string does.
#
# NOT compatible with --allow/$ALLOW_HOSTS -- same reason https-wrap.sh
# refuses it: the egress allowlist isolates the container's network
# namespace (including its own loopback), so Caddy, running outside the
# container on the host, can no longer reach ttyd. See https-wrap.sh's own
# guard/comment for the full explanation; this wrapper carries the same
# check.
#
# Usage:
#   pixi run terminal-https
#   pixi run terminal-https --ro-paths "/groups/scicompsoft" --https-port 8443
#   BACKEND=podman pixi run terminal-https   # force Podman even if Apptainer is on PATH
#
# Accepts (same style as container/common.sh):
#   --ro-paths PATHS   forwarded to shell-apptainer/shell-podman
#   --work PATH        forwarded to shell-apptainer/shell-podman
#   --https-port PORT  public TLS-terminating port Caddy listens on (default:
#                       an arbitrary free port, auto-selected)
#
# BACKEND=apptainer|podman (env var, not a flag) -- forces that backend
# regardless of what's on PATH; unset auto-detects (apptainer if present,
# else podman). See runnables.yaml's terminal-podman-https.
set -euo pipefail

trap 'echo ">> terminal-wrap: FATAL: \"$BASH_COMMAND\" failed (exit $?) at line $LINENO" >&2' ERR

cd "$(dirname "$0")/.."   # project root

# shellcheck source=container/caddy-lib.sh
source "container/caddy-lib.sh"

_set_phase() {
    [[ -n "${FG_PHASE_PATH:-}" ]] && printf '%s' "$1" > "$FG_PHASE_PATH" 2>/dev/null
    return 0
}

HTTPS_PORT=""
_args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --https-port)
            [[ -n "${2:-}" ]] && HTTPS_PORT="$2"
            shift 2
            ;;
        --https-port=*)
            _val="${1#--https-port=}"
            [[ -n "$_val" ]] && HTTPS_PORT="$_val"
            shift
            ;;
        *)
            _args+=("$1")
            shift
            ;;
    esac
done
set -- "${_args[@]}"
unset _args _val
[[ -z "$HTTPS_PORT" ]] && HTTPS_PORT="$(caddy_free_port)"
# caddy_free_port() only probes-then-releases a port (bind to 0, read the
# OS-assigned number, close) -- it doesn't hold it, so two calls in a row
# can (rarely) return the same number. Retry until INTERNAL_PORT actually
# differs from HTTPS_PORT, rather than let ttyd and Caddy silently contend
# for the same port.
INTERNAL_PORT="$(caddy_free_port)"
for _ in $(seq 1 10); do
    [[ "$INTERNAL_PORT" != "$HTTPS_PORT" ]] && break
    INTERNAL_PORT="$(caddy_free_port)"
done
if [[ "$INTERNAL_PORT" == "$HTTPS_PORT" ]]; then
    echo "ERROR: could not allocate distinct HTTPS/internal ports after 10 tries" >&2
    exit 1
fi

# See https-wrap.sh's identical guard for the full explanation: --allow
# isolates the container's loopback along with the rest of its network,
# which breaks Caddy's ability to reach ttyd entirely (a silent 502, not a
# working restricted-egress terminal).
_allow_seen="${ALLOW_HOSTS:-}"
for _a in "$@"; do
    case "$_a" in
        --allow|--allow=*) _allow_seen=1 ;;
    esac
done
if [[ -n "${_allow_seen// /}" ]]; then
    echo "ERROR: --allow/\$ALLOW_HOSTS is not compatible with terminal-wrap.sh -- the" >&2
    echo "       egress allowlist isolates the container's network namespace" >&2
    echo "       (including its loopback), so Caddy (running outside the container" >&2
    echo "       on the host) can no longer reach it. Use plain 'pixi run" >&2
    echo "       shell-apptainer/shell-podman -- ttyd ...' with --allow instead." >&2
    exit 1
fi
unset _allow_seen _a

WORK_VAL="${WORK:-}"
for ((i = 1; i <= $#; i++)); do
    case "${!i}" in
        --work) j=$((i + 1)); [[ -n "${!j:-}" ]] && WORK_VAL="${!j}" ;;
        --work=*) WORK_VAL="${!i#--work=}" ;;
    esac
done
WORK_VAL="${WORK_VAL:-$(pwd)/work}"

# Resolve the terminal's own token -- see this file's header comment for why
# it's kept independent of Marimo's .marimo-token.
if [[ -n "${FG_SERVICE_TOKEN:-}" ]]; then
    TOKEN="$FG_SERVICE_TOKEN"
elif [[ -f "$WORK_VAL/.terminal-token" ]]; then
    TOKEN="$(cat "$WORK_VAL/.terminal-token")"
else
    mkdir -p "$WORK_VAL"
    TOKEN="$(openssl rand -hex 16)"
    # Create with restrictive permissions from the start (umask in a
    # subshell, not a chmod afterward) -- this is an HTTP Basic Auth
    # password; a normal umask (e.g. 022) would otherwise leave it
    # world-readable for the window between creation and a separate chmod,
    # and permanently so on any host whose default umask allows it.
    (umask 077 && printf '%s' "$TOKEN" > "$WORK_VAL/.terminal-token")
fi

# Pick the backend, same auto-detection/override as https-wrap.sh.
case "${BACKEND:-}" in
    apptainer) SHELL_TASK=shell-apptainer ;;
    podman)    SHELL_TASK=shell-podman ;;
    "")
        if command -v apptainer &>/dev/null; then
            SHELL_TASK=shell-apptainer
        else
            SHELL_TASK=shell-podman
        fi
        ;;
    *)
        echo "ERROR: BACKEND must be 'apptainer' or 'podman' (got '$BACKEND')" >&2
        exit 1
        ;;
esac

# Launch ttyd INSIDE the sandbox via shell.sh's command-override support
# (see container/{apptainer,podman}/shell.sh) -- same read-only-host /
# writable-/work model and GPU passthrough an interactive shell.sh session
# gets, just running ttyd instead of dropping to an interactive shell
# directly. -i 127.0.0.1 keeps it off 0.0.0.0 so it's only reachable through
# the Caddy proxy, not directly (this relies on the container sharing the
# host's network, which is the default -- see the --allow guard above for
# why that default can't be turned off here). -W makes the terminal
# writable (ttyd is read-only/view-only by default). -c embeds the TOKEN
# resolved above as the HTTP Basic Auth password; the username ("terminal")
# is cosmetic.
echo ">> Starting web terminal via $SHELL_TASK (building its image first, if needed -- this can take several minutes on a fresh job) ..."
_set_phase pulling_image
pixi run "$SHELL_TASK" "$@" -- ttyd -i 127.0.0.1 -p "$INTERNAL_PORT" -W -c "terminal:$TOKEN" bash &
TERMINAL_PID=$!

cleanup() {
    kill "$TERMINAL_PID" "${CADDY_PID:-}" "${PUBLISHER_PID:-}" 2>/dev/null || true
    wait "$TERMINAL_PID" "${CADDY_PID:-}" "${PUBLISHER_PID:-}" 2>/dev/null || true
    rm -f "${CADDYFILE:-}"
}
trap cleanup EXIT INT TERM

echo ">> Waiting (up to 30s) for the web terminal to accept connections on 127.0.0.1:${INTERNAL_PORT} ..."
_terminal_up=0
for _ in $(seq 1 30); do
    if curl -sf -o /dev/null -u "terminal:$TOKEN" "http://127.0.0.1:$INTERNAL_PORT" 2>/dev/null; then
        _terminal_up=1
        break
    fi
    sleep 1
done
if [[ "$_terminal_up" -eq 1 ]]; then
    echo ">> Web terminal is accepting connections."
else
    echo ">> Web terminal hasn't responded yet after 30s (still building/starting); continuing -- Caddy will 502 until it's up."
fi
_set_phase starting

CERT_DIR="${FG_WORK_DIR:-$WORK_VAL}/https-cert"
caddy_generate_cert "$CERT_DIR" terminal-https

echo ">> HTTPS terminal: https://terminal:${TOKEN}@${HOST_NAME}:${HTTPS_PORT}/ -> 127.0.0.1:${INTERNAL_PORT}"
echo ">> Cert: $CERT_FILE -- install it in your browser's trust store to avoid the untrusted-certificate warning."
caddy_start "$HTTPS_PORT" "$INTERNAL_PORT"

caddy_publish_service_url "$HTTPS_PORT" "$TERMINAL_PID" \
    "https://terminal:${TOKEN}@${FG_HOSTNAME:-$HOST_NAME}:${HTTPS_PORT}/"

# Wait on EITHER the web terminal or Caddy, not just Caddy -- see
# https-wrap.sh's identical fix for the full reasoning (there, quitting
# Marimo left Caddy running and the job stuck forever; here the analogous
# case is the container itself exiting, e.g. a crash -- ttyd surviving a
# client's shell exiting is the common/expected case and does NOT trigger
# this, since ttyd itself keeps running to accept new connections).
#
# `|| true` and the 0/1 exit codes below: see https-wrap.sh's identical fix
# for why -- `wait -n` can legitimately return nonzero ("no such job") if the
# dying process was already reaped by the time this line runs, which would
# otherwise abort the script here under `set -e` before cleanup/messaging
# runs, and a second `wait` to recover its real exit code fails the same way.
wait -n "$TERMINAL_PID" "$CADDY_PID" 2>/dev/null || true
if ! kill -0 "$TERMINAL_PID" 2>/dev/null; then
    echo ">> Web terminal exited -- shutting down Caddy and this job too."
    _exit=0
else
    echo ">> Caddy exited unexpectedly -- shutting down the web terminal too."
    _exit=1
fi
wait "${PUBLISHER_PID:-}" 2>/dev/null || true
exit "$_exit"
