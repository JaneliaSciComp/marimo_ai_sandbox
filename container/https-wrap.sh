#!/usr/bin/env bash
#
# https-wrap.sh -- front the plain-HTTP Marimo server (started via the
# existing `pixi run marimo-apptainer` launcher) with a Caddy TLS-terminating
# reverse proxy.
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
#
# Accepts (same style as container/common.sh):
#   --ro-paths PATHS   forwarded to marimo-apptainer
#   --work PATH        forwarded to marimo-apptainer
#   --port PORT        internal Marimo port (default 8080)
#   --https-port PORT  public TLS-terminating port Caddy listens on (default: an
#                       arbitrary free port, auto-selected)
set -euo pipefail

cd "$(dirname "$0")/.."   # project root

# Finds a free TCP port the same way Fileglancer's own job runner does
# (bind-to-0 via python, falling back to probing the ephemeral range), since
# we can't assume the caller-supplied --https-port (if any) or a fixed
# default like 8443 is actually free on this host.
__free_port() {
    local p py i
    for py in python3 python; do
        if command -v "$py" >/dev/null 2>&1; then
            p="$("$py" -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null)" || true
            [[ -n "$p" ]] && { printf '%s' "$p"; return 0; }
        fi
    done
    for i in $(seq 1 50); do
        p=$(( (RANDOM % 16384) + 49152 ))
        if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
            printf '%s' "$p"; return 0
        fi
    done
    printf '%s' 8443
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
[[ -z "$HTTPS_PORT" ]] && HTTPS_PORT="$(__free_port)"

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

# Launch the existing marimo-apptainer task bound to the internal port, in
# the background. `-- --host 127.0.0.1` (marimo's own flag, passed through
# unmodified by marimo.sh/marimo.def) keeps it off 0.0.0.0 so it's only
# reachable through the Caddy proxy, not directly. Its stdout/stderr is
# tee'd to a log file so we can pull the access token out of Marimo's own
# startup banner ("URL: http://localhost:<port>?access_token=...") below,
# while still passing the output through to this script's own stdout.
MARIMO_LOG="$(mktemp)"
pixi run marimo-apptainer --port "$INTERNAL_PORT" "$@" -- --host 127.0.0.1 > >(tee "$MARIMO_LOG") 2>&1 &
MARIMO_PID=$!

cleanup() {
    kill "$MARIMO_PID" "${CADDY_PID:-}" 2>/dev/null || true
    wait "$MARIMO_PID" "${CADDY_PID:-}" 2>/dev/null || true
    rm -f "${CADDYFILE:-}" "$MARIMO_LOG"
}
trap cleanup EXIT INT TERM

# Wait for Marimo to come up before starting Caddy, to avoid a confusing 502.
for _ in $(seq 1 30); do
    curl -sf "http://127.0.0.1:$INTERNAL_PORT" >/dev/null 2>&1 && break
    sleep 1
done

# Pull the access token out of Marimo's banner so we can print an https://
# URL (with the same hostname used for the cert) that's directly usable,
# rather than the http://localhost:<port> one Marimo itself prints (which
# doesn't reflect the outer hostname/port Caddy is actually serving on).
ACCESS_TOKEN=""
for _ in $(seq 1 30); do
    ACCESS_TOKEN="$(grep -m1 -oE 'access_token=[A-Za-z0-9_-]+' "$MARIMO_LOG" 2>/dev/null | head -1 | cut -d= -f2)"
    [[ -n "$ACCESS_TOKEN" ]] && break
    sleep 1
done

# Generate a persistent self-signed cert/key the first time (or whenever the
# hostname changes, e.g. a new compute-node allocation), and reuse it on
# subsequent runs so the cert doesn't have to be re-trusted in the browser
# every time. Stored in the work directory alongside other job artifacts.
CERT_DIR="${FG_WORK_DIR:-$WORK_VAL}/https-cert"
CERT_FILE="$CERT_DIR/marimo-https.crt"
KEY_FILE="$CERT_DIR/marimo-https.key"
HOST_NAME="$(hostname -f 2>/dev/null || hostname)"

if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]] || ! openssl x509 -in "$CERT_FILE" -noout -checkhost "$HOST_NAME" >/dev/null 2>&1; then
    mkdir -p "$CERT_DIR"
    SAN="DNS:${HOST_NAME},DNS:$(hostname),DNS:localhost,IP:127.0.0.1"
    for _ip in $(hostname -I 2>/dev/null); do
        SAN="${SAN},IP:${_ip}"
    done
    echo ">> Generating self-signed HTTPS cert for ${HOST_NAME} (10-year validity)"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$KEY_FILE" -out "$CERT_FILE" -days 3650 \
        -subj "/CN=${HOST_NAME}" -addext "subjectAltName=${SAN}"
fi

if [[ -n "$ACCESS_TOKEN" ]]; then
    echo ">> HTTPS proxy: https://${HOST_NAME}:${HTTPS_PORT}?access_token=${ACCESS_TOKEN} -> 127.0.0.1:${INTERNAL_PORT}"
else
    echo ">> HTTPS proxy: https://${HOST_NAME}:${HTTPS_PORT} -> 127.0.0.1:${INTERNAL_PORT}"
fi
echo ">> Cert: $CERT_FILE -- install it in your browser's trust store to avoid the untrusted-certificate warning."
CADDYFILE="$(mktemp)"
cat > "$CADDYFILE" <<EOF
{
    admin off
    auto_https off
}

:${HTTPS_PORT} {
    tls ${CERT_FILE} ${KEY_FILE}
    reverse_proxy 127.0.0.1:${INTERNAL_PORT}
}
EOF
caddy run --config "$CADDYFILE" --adapter caddyfile &
CADDY_PID=$!

# Publish the service URL ourselves (Fileglancer's auto_url always writes
# http://$FG_HOSTNAME:$FG_SERVICE_PORT, which here would be Marimo's own
# plain-HTTP port, not Caddy's TLS one) once Caddy is actually accepting
# connections on HTTPS_PORT.
if [[ -n "${SERVICE_URL_PATH:-}" ]]; then
    _url_suffix=""
    [[ -n "$ACCESS_TOKEN" ]] && _url_suffix="?access_token=${ACCESS_TOKEN}"
    (
        for _ in $(seq 1 3600); do
            if (exec 3<>"/dev/tcp/127.0.0.1/$HTTPS_PORT") 2>/dev/null; then
                printf 'https://%s:%s/%s' "${FG_HOSTNAME:-$HOST_NAME}" "$HTTPS_PORT" "$_url_suffix" > "$SERVICE_URL_PATH"
                exit 0
            fi
            sleep 1
        done
        echo "https-wrap: port $HTTPS_PORT never opened; service URL not published." >&2
    ) &
fi

wait "$CADDY_PID"
