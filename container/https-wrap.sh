#!/usr/bin/env bash
#
# https-wrap.sh -- front the plain-HTTP Marimo server (started via the
# existing `pixi run marimo-apptainer` or `marimo-podman` launcher --
# apptainer if available, else podman, same fallback as [tasks.marimo] in
# pixi.toml) with a Caddy TLS-terminating reverse proxy.
#
# Marimo itself has no TLS support, so this wrapper is the HTTPS layer. We
# generate our own persistent self-signed cert with openssl and hand it to
# Caddy as a static file (`tls <cert> <key>`), rather than using Caddy's
# internal-CA issuer (`--internal-certs` / `tls internal`). Caddy's internal
# issuer is backed by its "pki" app, which -- the first time it mints a local
# CA -- shells out to `sudo` to install that CA's root into the OS trust
# store. There is no supported way to turn this off in this Caddy version's
# Caddyfile/JSON schema (`skip_install_trust` on the issuer and `installed`
# on the pki CA are both rejected as unrecognized fields), and the sudo call
# hangs/fails on a host with no interactive sudo session (e.g. a compute
# node). Providing our own cert file sidesteps the internal issuer -- and
# the pki app -- entirely, so that code path never runs. It also means the
# certificate persists across restarts instead of being regenerated (and
# needing browser re-trust) every run.
#
# `auto_https off` is required, not just `disable_redirects`: a Caddyfile
# site address of `https://0.0.0.0:<port>` only matches requests whose Host
# header is literally "0.0.0.0". Real requests (Host: the actual hostname)
# fall through to Caddy's automatic-HTTPS default handling for the
# connection, which manages its own cert via the internal issuer/pki app --
# triggering the same sudo call this wrapper exists to avoid, regardless of
# the static cert configured above. `auto_https off` (with a bare `:<port>`
# address, no scheme/host) disables all automatic cert management so every
# connection is served by our static cert.
#
# Usage:
#   pixi run marimo-https
#   pixi run marimo-https --ro-paths "/groups/scicompsoft" --port 8080 --https-port 8443
#   BACKEND=podman pixi run marimo-https   # force Podman even if Apptainer is on PATH
#
# Accepts (same style as container/common.sh):
#   --ro-paths PATHS   forwarded to marimo-apptainer/marimo-podman
#   --work PATH        forwarded to marimo-apptainer/marimo-podman
#   --port PORT        internal Marimo port (default 8080)
#   --https-port PORT  public TLS-terminating port Caddy listens on (default: an
#                       arbitrary free port, auto-selected)
#
# BACKEND=apptainer|podman (env var, not a flag) -- forces that backend
# regardless of what's on PATH; unset auto-detects (apptainer if present,
# else podman). See runnables.yaml's marimo-podman-https for why this exists.
set -euo pipefail

# Under set -e a failing command just kills the script with no explanation,
# which previously looked like Marimo's image build itself failing (it
# hadn't -- the failure was elsewhere, seconds after start). Log what
# actually failed and where before `cleanup` (registered further down) runs.
trap 'echo ">> https-wrap: FATAL: \"$BASH_COMMAND\" failed (exit $?) at line $LINENO" >&2' ERR

cd "$(dirname "$0")/.."   # project root

# shellcheck source=container/caddy-lib.sh
source "container/caddy-lib.sh"

# Reports coarse startup progress to Fileglancer's phase file (set only when
# this runs as a Fileglancer service job), which its UI reads to explain a
# wait before the service URL appears. Only "pulling_image" and "starting"
# are recognized values (see fileglancer's jobfiles.py); we reuse them
# loosely here since our own image build (via marimo-apptainer/marimo-podman,
# below) plays the same role as an image pull.
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

# --allow/$ALLOW_HOSTS (the network egress allowlist, both backends -- see
# container/common.sh's network_allowlist_* and container/{podman,apptainer}
# /lib.sh) is NOT compatible with this wrapper: the allowlist puts the
# container's network in its own isolated namespace (--network=none for
# Podman, --net --network none for Apptainer, plus a bind-mounted proxy
# socket), which also isolates its loopback -- Caddy, which runs OUTSIDE the
# container on the host, can then no longer reach Marimo's
# 127.0.0.1:$INTERNAL_PORT at all. Confirmed live: this previously failed
# silently with a plain 502 from Caddy, no error explaining why -- hard-error
# here instead, before wasting time building/pulling the image.
_allow_seen="${ALLOW_HOSTS:-}"
for _a in "$@"; do
    case "$_a" in
        --allow|--allow=*) _allow_seen=1 ;;
    esac
done
if [[ -n "${_allow_seen// /}" ]]; then
    echo "ERROR: --allow/\$ALLOW_HOSTS is not compatible with https-wrap.sh -- the" >&2
    echo "       egress allowlist isolates the container's network namespace" >&2
    echo "       (including its loopback), so Caddy (running outside the container" >&2
    echo "       on the host) can no longer reach it; the result is a silent 502," >&2
    echo "       not a working restricted-egress HTTPS service. Use the plain-HTTP" >&2
    echo "       marimo-apptainer/marimo-podman tasks with --allow instead." >&2
    exit 1
fi
unset _allow_seen _a

INTERNAL_PORT="8080"
WORK_VAL="${WORK:-}"
for ((i = 1; i <= $#; i++)); do
    case "${!i}" in
        --port)
            j=$((i + 1))
            [[ -n "${!j:-}" ]] && INTERNAL_PORT="${!j}"
            ;;
        --port=*)
            INTERNAL_PORT="${!i#--port=}"
            ;;
        --work)
            j=$((i + 1))
            [[ -n "${!j:-}" ]] && WORK_VAL="${!j}"
            ;;
        --work=*)
            WORK_VAL="${!i#--work=}"
            ;;
    esac
done
WORK_VAL="${WORK_VAL:-$(pwd)/work}"

# Resolve marimo's token up front (same idiom as container/entrypoint.sh,
# which this WORK_VAL/.marimo-token path is shared with -- WORK_VAL here and
# /work inside the container are the same bind-mounted directory): prefer
# FG_SERVICE_TOKEN if this is a Fileglancer job, else reuse/generate a
# random token persisted at "$WORK_VAL/.marimo-token" so local restarts get
# the same value. Passed through explicitly below so entrypoint.sh sees it
# already set (via its own "$@" scan) instead of independently resolving
# it, and so we know it here synchronously instead of scraping it out of
# Marimo's stdout after the fact.
if [[ -n "${FG_SERVICE_TOKEN:-}" ]]; then
    TOKEN="$FG_SERVICE_TOKEN"
elif [[ -f "$WORK_VAL/.marimo-token" ]]; then
    TOKEN="$(cat "$WORK_VAL/.marimo-token")"
else
    mkdir -p "$WORK_VAL"
    TOKEN="$(openssl rand -hex 16)"
    printf '%s' "$TOKEN" > "$WORK_VAL/.marimo-token"
fi

# Pick the backend to run Marimo through. Default (BACKEND unset): the same
# auto-detection the plain-HTTP `pixi run marimo` task uses (see
# [tasks.marimo] in pixi.toml) -- apptainer if it's on PATH, else podman.
# This is a plain PATH check, not the pixi "apptainer" feature/environment
# -- the https feature deliberately doesn't pull that in (see pixi.toml), so
# this stays podman-only on hosts without apptainer instead of quietly
# requiring it via pixi.
#
# Set BACKEND=podman (or =apptainer) to force a specific backend regardless
# of what's on PATH -- e.g. the marimo-podman-https runnable in
# runnables.yaml uses this to get Podman+HTTPS on a host that also has
# Apptainer installed, since auto-detection alone always prefers Apptainer
# when both are present.
case "${BACKEND:-}" in
    apptainer) MARIMO_TASK=marimo-apptainer ;;
    podman)    MARIMO_TASK=marimo-podman ;;
    "")
        if command -v apptainer &>/dev/null; then
            MARIMO_TASK=marimo-apptainer
        else
            MARIMO_TASK=marimo-podman
        fi
        ;;
    *)
        echo "ERROR: BACKEND must be 'apptainer' or 'podman' (got '$BACKEND')" >&2
        exit 1
        ;;
esac

# Launch the existing marimo-apptainer/marimo-podman task bound to the
# internal port, in the background. `--host 127.0.0.1` (marimo's own flag,
# passed through unmodified by marimo.sh/marimo.def/Containerfile) keeps it
# off 0.0.0.0 so it's only reachable through the Caddy proxy, not directly.
# `--token-password "$TOKEN"` makes the token the one resolved above, rather
# than a hidden random one only discoverable by scraping stdout.
#
# No `--` separator here (unlike [tasks.marimo]/[tasks.shell] in pixi.toml,
# which need one to mark the end of their own templated positional args):
# marimo-apptainer/marimo-podman are bare-command tasks with no declared
# args, so a literal "--" isn't consumed by pixi, common.sh, marimo.sh, or
# entrypoint.sh -- it rides straight through into marimo's own Click-based
# CLI, which treats "--" as "stop parsing options, everything after this is
# positional." That silently swallowed --host/--token-password as ignored
# positional args, so marimo fell back to generating its own random token
# instead of honoring $TOKEN -- confirmed: the token this published in
# SERVICE_URL_PATH didn't match the token marimo actually enforced.
echo ">> Starting Marimo via $MARIMO_TASK (building its image first, if needed -- this can take several minutes on a fresh job) ..."
_set_phase pulling_image
pixi run "$MARIMO_TASK" --port "$INTERNAL_PORT" "$@" --host 127.0.0.1 --token-password "$TOKEN" &
MARIMO_PID=$!

cleanup() {
    kill "$MARIMO_PID" "${CADDY_PID:-}" "${PUBLISHER_PID:-}" 2>/dev/null || true
    wait "$MARIMO_PID" "${CADDY_PID:-}" "${PUBLISHER_PID:-}" 2>/dev/null || true
    rm -f "${CADDYFILE:-}"
}
trap cleanup EXIT INT TERM

# Wait for Marimo to come up before starting Caddy, to avoid a confusing 502.
# This budget (30s) is deliberately much shorter than a fresh image build can
# take -- it only exists to skip the confusing-502 window on a warm start; a
# timeout here just means Caddy comes up before Marimo does, which is fine.
echo ">> Waiting (up to 30s) for Marimo to accept connections on 127.0.0.1:${INTERNAL_PORT} ..."
_marimo_up=0
for _ in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:$INTERNAL_PORT" >/dev/null 2>&1; then
        _marimo_up=1
        break
    fi
    sleep 1
done
if [[ "$_marimo_up" -eq 1 ]]; then
    echo ">> Marimo is accepting connections."
else
    echo ">> Marimo hasn't responded yet after 30s (still building/starting); continuing -- Caddy will 502 until it's up."
fi
_set_phase starting

# Generate a persistent self-signed cert/key the first time (or whenever the
# hostname changes, e.g. a new compute-node allocation), and reuse it on
# subsequent runs so the cert doesn't have to be re-trusted in the browser
# every time. Stored in the work directory alongside other job artifacts.
CERT_DIR="${FG_WORK_DIR:-$WORK_VAL}/https-cert"
caddy_generate_cert "$CERT_DIR" marimo-https

echo ">> HTTPS proxy: https://${HOST_NAME}:${HTTPS_PORT}?access_token=${TOKEN} -> 127.0.0.1:${INTERNAL_PORT}"
echo ">> Cert: $CERT_FILE -- install it in your browser's trust store to avoid the untrusted-certificate warning."
caddy_start "$HTTPS_PORT" "$INTERNAL_PORT"

# Publish the service URL ourselves (Fileglancer's auto_url always writes
# http://$FG_HOSTNAME:$FG_SERVICE_PORT, which here would be Marimo's own
# plain-HTTP port, not Caddy's TLS one) once Caddy is actually accepting
# connections on HTTPS_PORT. $TOKEN is already known up front now (resolved
# before Marimo even started), so unlike before, there's nothing left to
# wait on besides the port itself.
caddy_publish_service_url "$HTTPS_PORT" "$MARIMO_PID" \
    "https://${FG_HOSTNAME:-$HOST_NAME}:${HTTPS_PORT}/?access_token=${TOKEN}"

wait "$CADDY_PID"
wait "${PUBLISHER_PID:-}" 2>/dev/null || true
