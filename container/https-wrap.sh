#!/usr/bin/env bash
#
# https-wrap.sh -- front the plain-HTTP Marimo server (started via the
# existing `pixi run marimo-apptainer` launcher) with a Caddy TLS-terminating
# reverse proxy, using Caddy's --internal-certs (a locally-generated CA and
# leaf cert; no cert files to create or manage by hand).
#
# Marimo itself has no TLS support, so this wrapper is the HTTPS layer:
#   caddy reverse-proxy --from https://0.0.0.0:<https-port> \
#       --to 127.0.0.1:<internal-port> --internal-certs --disable-redirects
# (--disable-redirects skips binding the privileged :80 HTTP->HTTPS redirect
# listener, which fails without root; --from needs an explicit host/scheme
# or Caddy silently serves plain HTTP instead of TLS.)
#
# Usage:
#   pixi run marimo-https
#   pixi run marimo-https --ro-paths "/groups/scicompsoft" --port 8080 --https-port 8443
#
# Accepts (same style as container/common.sh):
#   --ro-paths PATHS   forwarded to marimo-apptainer
#   --work PATH        forwarded to marimo-apptainer
#   --port PORT        internal Marimo port (default 8080)
#   --https-port PORT  public TLS-terminating port Caddy listens on (default 8443)
set -euo pipefail

cd "$(dirname "$0")/.."   # project root

HTTPS_PORT="8443"
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
# reachable through the Caddy proxy, not directly.
pixi run marimo-apptainer --port "$INTERNAL_PORT" "$@" -- --host 127.0.0.1 &
MARIMO_PID=$!

cleanup() {
    kill "$MARIMO_PID" "${CADDY_PID:-}" 2>/dev/null || true
    wait "$MARIMO_PID" "${CADDY_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Wait for Marimo to come up before starting Caddy, to avoid a confusing 502.
for _ in $(seq 1 30); do
    curl -sf "http://127.0.0.1:$INTERNAL_PORT" >/dev/null 2>&1 && break
    sleep 1
done

echo ">> HTTPS proxy: https://0.0.0.0:${HTTPS_PORT} -> 127.0.0.1:${INTERNAL_PORT}"
caddy reverse-proxy --from "https://0.0.0.0:${HTTPS_PORT}" --to "127.0.0.1:${INTERNAL_PORT}" \
    --internal-certs --disable-redirects &
CADDY_PID=$!

# Caddy's local CA root cert is generated on first startup of the TLS
# module, so poll for it rather than assuming it already exists. Copy it
# into the job's work directory and print its path -- install it in your
# browser's trust store to avoid the untrusted-certificate warning.
CADDY_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/caddy"
CA_CERT_SRC="$CADDY_DATA_DIR/pki/authorities/local/root.crt"
CA_CERT_DEST_DIR="${FG_WORK_DIR:-$WORK_VAL}"
for _ in $(seq 1 30); do
    if [[ -f "$CA_CERT_SRC" ]]; then
        cp -f "$CA_CERT_SRC" "$CA_CERT_DEST_DIR/caddy-local-ca.crt"
        echo ">> Caddy local CA root cert: $CA_CERT_DEST_DIR/caddy-local-ca.crt"
        echo ">> Install it in your browser's trust store to avoid the untrusted-certificate warning."
        break
    fi
    sleep 1
done

wait "$CADDY_PID"
