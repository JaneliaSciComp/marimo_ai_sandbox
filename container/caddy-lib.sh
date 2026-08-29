#!/usr/bin/env bash
#
# caddy-lib.sh -- shared Caddy/TLS-cert helpers, sourced by
# container/{https,terminal}-wrap.sh. Not meant to be executed directly.
#
# Factored out of the original https-wrap.sh (Marimo-over-HTTPS) so
# terminal-wrap.sh (a web terminal over HTTPS) can reuse the exact same
# self-signed-cert/Caddyfile/service-URL-publishing machinery instead of
# duplicating it -- only the thing being reverse-proxied differs.

# caddy_free_port -- finds a free TCP port the same way Fileglancer's own
# job runner does (bind-to-0 via python, falling back to probing the
# ephemeral range), since we can't assume a caller-supplied port (or a
# fixed default) is actually free on this host.
caddy_free_port() {
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

# caddy_generate_cert -- generates a persistent self-signed cert/key the
# first time (or whenever the hostname changes, e.g. a new compute-node
# allocation) under CERT_DIR, and reuses it on subsequent runs so the cert
# doesn't have to be re-trusted in the browser every time.
#
# Usage: caddy_generate_cert CERT_DIR CERT_NAME
#   (files are written as CERT_DIR/CERT_NAME.crt and .key)
#
# Sets: CERT_FILE, KEY_FILE, HOST_NAME
caddy_generate_cert() {
    local cert_dir="$1" cert_name="$2"
    CERT_FILE="$cert_dir/$cert_name.crt"
    KEY_FILE="$cert_dir/$cert_name.key"
    HOST_NAME="$(hostname -f 2>/dev/null || hostname)"

    if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]] || ! openssl x509 -in "$CERT_FILE" -noout -checkhost "$HOST_NAME" >/dev/null 2>&1; then
        mkdir -p "$cert_dir"
        local san="DNS:${HOST_NAME},DNS:$(hostname),DNS:localhost,IP:127.0.0.1"
        local _ip
        for _ip in $(hostname -I 2>/dev/null); do
            san="${san},IP:${_ip}"
        done
        echo ">> Generating self-signed HTTPS cert for ${HOST_NAME} (10-year validity)"
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
            -keyout "$KEY_FILE" -out "$CERT_FILE" -days 3650 \
            -subj "/CN=${HOST_NAME}" -addext "subjectAltName=${san}"
    else
        echo ">> Reusing existing HTTPS cert for ${HOST_NAME} ($CERT_FILE)"
    fi
}

# caddy_start -- writes a minimal Caddyfile TLS-terminating HTTPS_PORT and
# reverse-proxying to 127.0.0.1:INTERNAL_PORT, using the static cert from
# caddy_generate_cert (never Caddy's own internal-CA issuer -- see
# https-wrap.sh's header comment for why: that issuer shells out to `sudo`
# on first use, which hangs on a host with no interactive sudo session).
#
# Usage: caddy_start HTTPS_PORT INTERNAL_PORT
#
# Sets: CADDYFILE, CADDY_PID
caddy_start() {
    local https_port="$1" internal_port="$2"
    echo ">> Starting Caddy on :${https_port} -> 127.0.0.1:${internal_port} ..."
    CADDYFILE="$(mktemp)"
    cat > "$CADDYFILE" <<EOF
{
    admin off
    auto_https off
}

:${https_port} {
    tls ${CERT_FILE} ${KEY_FILE}
    reverse_proxy 127.0.0.1:${internal_port}
}
EOF
    caddy run --config "$CADDYFILE" --adapter caddyfile &
    CADDY_PID=$!
}

# caddy_publish_service_url -- once Caddy is actually accepting connections
# on HTTPS_PORT (and both the backend service and Caddy are still alive),
# writes the given URL to $SERVICE_URL_PATH -- Fileglancer's own auto_url
# would otherwise publish the backend's plain-HTTP port instead of Caddy's
# TLS one. No-op (with a warning) if $SERVICE_URL_PATH isn't set at all.
#
# Usage: caddy_publish_service_url HTTPS_PORT SERVICE_PID URL
#   SERVICE_PID -- the backend service's PID (Marimo, ttyd, ...); the
#                  publisher gives up if either this or Caddy dies first.
#
# Sets: PUBLISHER_PID (backgrounds itself; "" if SERVICE_URL_PATH is unset)
caddy_publish_service_url() {
    local https_port="$1" service_pid="$2" url="$3"
    PUBLISHER_PID=""
    if [[ -z "${SERVICE_URL_PATH:-}" ]]; then
        echo ">> WARNING: \$SERVICE_URL_PATH is not set -- the service URL cannot be published to Fileglancer, so no launch link will ever appear for this job." >&2
        return 0
    fi
    (
        for _ in $(seq 1 1800); do
            if ! kill -0 "$service_pid" 2>/dev/null; then
                echo "caddy-lib: backend service process died before HTTPS port opened; service URL not published." >&2
                exit 1
            fi
            if ! kill -0 "$CADDY_PID" 2>/dev/null; then
                echo "caddy-lib: Caddy process died before HTTPS port opened; service URL not published." >&2
                exit 1
            fi
            if (exec 3<>"/dev/tcp/127.0.0.1/$https_port") 2>/dev/null; then
                printf '%s' "$url" > "$SERVICE_URL_PATH"
                echo ">> Published service URL to $SERVICE_URL_PATH"
                exit 0
            fi
            sleep 1
        done
        echo "caddy-lib: port $https_port never opened; service URL not published." >&2
    ) &
    PUBLISHER_PID=$!
}
