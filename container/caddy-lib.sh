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
# If the `pca` CLI (github.com/JaneliaSciComp/personal-certificate-authority)
# is on PATH, it's preferred over the self-signed cert below: a pca-issued
# cert is signed by a CA that `pca init`/`pca trust` actually installs into a
# trust store, so a browser (or any HTTP client) that trusts that CA sees a
# normal HTTPS connection instead of a self-signed-cert warning -- and
# unlike a self-signed cert, it doesn't run into the "self-signed certs
# break CORS/fetch" problem Fileglancer's own docs warn about for its main
# server. This is purely opportunistic: it falls straight back to the
# self-signed path when `pca` isn't installed or hasn't been initialized
# (`pca init`), so nothing changes for anyone who hasn't opted in.
#
# Usage: caddy_generate_cert CERT_DIR CERT_NAME
#   (self-signed files are written as CERT_DIR/CERT_NAME.crt and .key; a
#   pca-issued cert instead lives under pca's own data directory, keyed by
#   the same CERT_NAME, and CERT_DIR is unused in that path)
#
# Sets: CERT_FILE, KEY_FILE, HOST_NAME
caddy_generate_cert() {
    local cert_dir="$1" cert_name="$2"
    HOST_NAME="$(hostname -f 2>/dev/null || hostname)"

    if command -v pca >/dev/null 2>&1; then
        local pca_data_dir="${PCA_DATA_DIR:-$HOME/.local/share/personal-certificate-authority}"
        local pca_cert="$pca_data_dir/certs/$cert_name/cert.pem"
        local pca_key="$pca_data_dir/certs/$cert_name/key.pem"
        local -a pca_sans
        pca_sans=(--san "$HOST_NAME" --san "$(hostname)" --san localhost --san 127.0.0.1)
        local _ip
        for _ip in $(hostname -I 2>/dev/null); do
            pca_sans+=(--san "$_ip")
        done
        if pca issue --name "$cert_name" "${pca_sans[@]}" && [[ -f "$pca_cert" && -f "$pca_key" ]]; then
            CERT_FILE="$pca_cert"
            KEY_FILE="$pca_key"
            echo ">> Using pca-issued HTTPS cert for ${HOST_NAME} ($CERT_FILE)"
            return 0
        fi
        echo ">> WARNING: 'pca' is on PATH but issuing a certificate failed; falling back to a self-signed cert." >&2
    fi

    CERT_FILE="$cert_dir/$cert_name.crt"
    KEY_FILE="$cert_dir/$cert_name.key"

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

# caddy_hash_password -- hashes PASSWORD (e.g. a service token) with `caddy
# hash-password`, for use in a `basic_auth` Caddyfile block (which requires a
# bcrypt/argon2id hash, not plaintext). Fed via stdin, not `--plaintext`, so
# the password never appears in this (or caddy's) process argv -- other
# users on the host can read another process's argv via `ps`. A trailing
# newline is required: `caddy hash-password` reads stdin as a line, and
# hashes it without the newline itself (confirmed live: a hash produced this
# way for "$TOKEN\n" validates against "$TOKEN" in a running Caddy
# basic_auth block).
#
# Usage: caddy_hash_password PASSWORD
caddy_hash_password() {
    printf '%s\n' "$1" | caddy hash-password --algorithm bcrypt
}

# caddy_start -- writes a minimal Caddyfile reverse-proxying PORT to
# 127.0.0.1:INTERNAL_PORT. By default (no leading --http) it terminates TLS
# using the static cert from caddy_generate_cert (never Caddy's own
# internal-CA issuer -- see https-wrap.sh's header comment for why: that
# issuer shells out to `sudo` on first use, which hangs on a host with no
# interactive sudo session). Pass --http as the first argument for the
# standard-security tier (no TLS block at all, plain HTTP) -- the caller
# must not call caddy_generate_cert in that case, since there's no cert to
# use.
#
# With no auth args, reverse-proxies with no auth of its own (the backend,
# e.g. Marimo, does its own token check). Passing all three trailing args
# additionally gates the route with HTTP Basic Auth (checked by Caddy
# itself, using a pre-hashed password -- see caddy_hash_password) and
# injects a static, non-secret header into the proxied request for a
# backend (e.g. ttyd's `-H/--auth-header`) that trusts its reverse proxy to
# have already authenticated the caller instead of checking credentials
# itself -- see terminal-wrap.sh for why: ttyd's own `-c user:pass` auth has
# no env/file option, so its credential would otherwise have to be passed on
# its command line (visible via `ps`).
#
# Usage: caddy_start [--http] PORT INTERNAL_PORT [BASIC_AUTH_USER BASIC_AUTH_HASH AUTH_HEADER_NAME]
#
# Sets: CADDYFILE, CADDY_PID
caddy_start() {
    local use_tls=1
    if [[ "${1:-}" == "--http" ]]; then
        use_tls=0
        shift
    fi
    local https_port="$1" internal_port="$2"
    local auth_user="${3:-}" auth_hash="${4:-}" auth_header="${5:-}"
    echo ">> Starting Caddy on :${https_port} -> 127.0.0.1:${internal_port} ..."
    CADDYFILE="$(mktemp)"
    {
        cat <<EOF
{
    admin off
    auto_https off
}

:${https_port} {
EOF
        [[ "$use_tls" -eq 1 ]] && printf '    tls %s %s\n' "$CERT_FILE" "$KEY_FILE"
        if [[ -n "$auth_user" ]]; then
            cat <<EOF
    basic_auth {
        ${auth_user} ${auth_hash}
    }
    reverse_proxy 127.0.0.1:${internal_port} {
        header_up ${auth_header} "ok"
    }
}
EOF
        else
            cat <<EOF
    reverse_proxy 127.0.0.1:${internal_port}
}
EOF
        fi
    } > "$CADDYFILE"
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
