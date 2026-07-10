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
#
# Accepts (same style as container/common.sh):
#   --ro-paths PATHS   forwarded to marimo-apptainer/marimo-podman
#   --work PATH        forwarded to marimo-apptainer/marimo-podman
#   --port PORT        internal Marimo port (default 8080)
#   --https-port PORT  public TLS-terminating port Caddy listens on (default: an
#                       arbitrary free port, auto-selected)
set -euo pipefail

# Under set -e a failing command just kills the script with no explanation,
# which previously looked like Marimo's image build itself failing (it
# hadn't -- the failure was elsewhere, seconds after start). Log what
# actually failed and where before `cleanup` (registered further down) runs.
trap 'echo ">> https-wrap: FATAL: \"$BASH_COMMAND\" failed (exit $?) at line $LINENO" >&2' ERR

cd "$(dirname "$0")/.."   # project root

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

# Pick the same backend the plain-HTTP `pixi run marimo` task would (see
# [tasks.marimo] in pixi.toml): apptainer if it's on PATH, else podman. This
# is a plain PATH check, not the pixi "apptainer" feature/environment -- the
# https feature deliberately doesn't pull that in (see pixi.toml), so this
# stays podman-only on hosts without apptainer instead of quietly requiring
# it via pixi.
if command -v apptainer &>/dev/null; then
    MARIMO_TASK=marimo-apptainer
else
    MARIMO_TASK=marimo-podman
fi

# Launch the existing marimo-apptainer/marimo-podman task bound to the
# internal port, in the background. `-- --host 127.0.0.1` (marimo's own
# flag, passed through unmodified by marimo.sh/marimo.def/Containerfile)
# keeps it off 0.0.0.0 so it's only reachable through the Caddy proxy, not
# directly. `--token-password "$TOKEN"` makes the token the one resolved
# above, rather than a hidden random one only discoverable by scraping
# stdout.
echo ">> Starting Marimo via $MARIMO_TASK (building its image first, if needed -- this can take several minutes on a fresh job) ..."
_set_phase pulling_image
pixi run "$MARIMO_TASK" --port "$INTERNAL_PORT" "$@" -- --host 127.0.0.1 --token-password "$TOKEN" &
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
else
    echo ">> Reusing existing HTTPS cert for ${HOST_NAME} ($CERT_FILE)"
fi

echo ">> HTTPS proxy: https://${HOST_NAME}:${HTTPS_PORT}?access_token=${TOKEN} -> 127.0.0.1:${INTERNAL_PORT}"
echo ">> Cert: $CERT_FILE -- install it in your browser's trust store to avoid the untrusted-certificate warning."
echo ">> Starting Caddy on :${HTTPS_PORT} ..."
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
# connections on HTTPS_PORT. $TOKEN is already known up front now (resolved
# before Marimo even started), so unlike before, there's nothing left to
# wait on besides the port itself.
if [[ -n "${SERVICE_URL_PATH:-}" ]]; then
    (
        for _ in $(seq 1 1800); do
            if (exec 3<>"/dev/tcp/127.0.0.1/$HTTPS_PORT") 2>/dev/null; then
                printf 'https://%s:%s/?access_token=%s' "${FG_HOSTNAME:-$HOST_NAME}" "$HTTPS_PORT" "$TOKEN" > "$SERVICE_URL_PATH"
                echo ">> Published service URL to $SERVICE_URL_PATH"
                exit 0
            fi
            sleep 1
        done
        echo "https-wrap: port $HTTPS_PORT never opened; service URL not published." >&2
    ) &
    PUBLISHER_PID=$!
fi

wait "$CADDY_PID"
