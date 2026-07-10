#!/usr/bin/env bash
#
# common.sh -- sourced by start.sh, shell.sh, run_podman.sh, shell_podman.sh.
# Not meant to be executed directly.
#
# Reads (uses defaults if unset):
#   WORK, PORT, RO_PATHS
#   CLAUDE_CONFIG, GEMINI_CONFIG, CODEX_CONFIG -- each "rw", "ro", or unset
#   (default: unset, i.e. not mounted at all -- see the BIND_PAIRS section
#   below for why)
#
# Also accepts on the caller's "$@" (highest precedence, overrides the env
# var and conf/config.toml; consumed here, remaining args are left in "$@"
# for the caller to forward on):
#   --ro-paths PATHS   or   --ro-paths=PATHS   (space-separated, same format as RO_PATHS)
#   --work PATH        or   --work=PATH
#   --port PORT        or   --port=PORT
#
# Sets:
#   WORK, PORT, RO_PATHS
#   BIND_PAIRS  -- "src:dst[:options]" strings; callers prefix with -v or --bind
#   ENV_PAIRS   -- "NAME=VALUE" strings;        callers prefix with -e or --env
#
# Side-effects:
#   Creates $WORK/home and $WORK/tmp.
#   Seeds $WORK with starter notebooks on first run.

# Parse --ro-paths/--work/--port from the caller's args. An empty value (e.g.
# a pixi task's unset-argument default) is ignored so the env var /
# conf/config.toml still apply; a non-empty value wins over both.
_args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ro-paths)
            [[ -n "${2:-}" ]] && RO_PATHS="$2"
            shift 2
            ;;
        --ro-paths=*)
            _val="${1#--ro-paths=}"
            [[ -n "$_val" ]] && RO_PATHS="$_val"
            shift
            ;;
        --work)
            [[ -n "${2:-}" ]] && WORK="$2"
            shift 2
            ;;
        --work=*)
            _val="${1#--work=}"
            [[ -n "$_val" ]] && WORK="$_val"
            shift
            ;;
        --port)
            [[ -n "${2:-}" ]] && PORT="$2"
            shift 2
            ;;
        --port=*)
            _val="${1#--port=}"
            [[ -n "$_val" ]] && PORT="$_val"
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

# Scripts cd to their own directory before sourcing this file, so $PWD is
# container/apptainer/ or container/podman/.  The project root is two levels up.
_PROJECT_ROOT="$(cd "$PWD/../.." && pwd)"

# Load conf/config.toml if present, setting WORK, PORT, RO_PATHS from it
# (only when not already set in the environment).
#
# Run via `pixi run --manifest-path .../container/app/pyproject.toml` rather
# than a bare `python3` -- the host's system python3 is not to be relied on
# (may be too old for tomllib, or simply absent from PATH); the
# user-editable pixi project (see container/entrypoint.sh) is the one
# Python this repo guarantees, so use it explicitly.
_CONFIG="$_PROJECT_ROOT/conf/config.toml"
[[ ! -f "$_CONFIG" ]] && _CONFIG="$_PROJECT_ROOT/conf/config.default.toml"
_APP_MANIFEST="$_PROJECT_ROOT/container/app/pyproject.toml"
if [[ -f "$_CONFIG" ]]; then
    _toml_all="$(pixi run --manifest-path "$_APP_MANIFEST" python3 -c "
import tomllib
with open('$_CONFIG', 'rb') as f:
    d = tomllib.load(f)
print(d.get('work', ''))
print(d.get('port', ''))
print(' '.join(d.get('ro_paths', [])))
" 2>/dev/null)"
    _toml_work="$(sed -n '1p' <<<"$_toml_all")"
    _toml_port="$(sed -n '2p' <<<"$_toml_all")"
    _toml_ro="$(sed -n '3p' <<<"$_toml_all")"
    [[ -n "$_toml_work" ]] && WORK="${WORK:-$_toml_work}"
    [[ -n "$_toml_port" ]] && PORT="${PORT:-$_toml_port}"
    [[ -n "$_toml_ro"   ]] && RO_PATHS="${RO_PATHS:-$_toml_ro}"
    unset _toml_all _toml_work _toml_port _toml_ro
fi
unset _CONFIG _APP_MANIFEST

WORK="${WORK:-$_PROJECT_ROOT/work}"
PORT="${PORT:-8080}"
unset _PROJECT_ROOT

RO_PATHS="${RO_PATHS:-}"

# Prepare the writable work dir.
mkdir -p "$WORK"/home "$WORK"/tmp

# Seed the work dir with starter notebooks on first run.
if [[ -d ../app ]] && ! compgen -G "$WORK/*.py" >/dev/null; then
    cp -n ../app/*.py "$WORK"/ 2>/dev/null || true
fi

# Seed the work dir with a user-editable pixi project (Python/marimo/
# data-science packages) on first run. entrypoint.sh installs it into
# $WORK/.pixi and runs Marimo from there instead of the image's read-only
# baked-in env, so `pixi add <package>` (from a notebook or a shell) and
# editing $WORK/pyproject.toml on the host both work without touching the
# container image.
if [[ -f ../app/pyproject.toml ]] && [[ ! -f "$WORK/pyproject.toml" ]]; then
    cp -n ../app/pyproject.toml ../app/pixi.lock "$WORK"/ 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# BIND_PAIRS -- one "src:dst[:options]" entry per mount.
# Callers convert with:  -v "$pair"       (podman)
#                        --bind "$pair"   (apptainer)
# ---------------------------------------------------------------------------
BIND_PAIRS=("$WORK:/work:rw")

# Agent credential dirs (.claude/.gemini/.codex) are NOT mounted by
# default. They used to always be bound in (writable, or read-only via a
# single RO_AGENT_CONFIG flag covering all three), which meant every launch
# touched the host's real config -- for tools/credentials a given job might
# not even use -- whether or not that job wanted it. Now each is opt-in and
# independently controlled: set CLAUDE_CONFIG/GEMINI_CONFIG/CODEX_CONFIG to
# "rw" or "ro" to bind that tool's real host config dir that way; leave
# unset to skip it entirely (that tool starts with no config/credentials
# inside the sandbox). Whether to seed /work/home/.claude (etc.) by copying
# host config there first, instead of a live bind, is left to the user --
# not done automatically here.
_bind_agent_config() {
    local var="$1" dir="$2" mode="${!1:-}"
    case "$mode" in
        rw) [[ -d "$HOME/$dir" ]] && BIND_PAIRS+=("$HOME/$dir:/work/home/$dir") ;;
        ro) [[ -d "$HOME/$dir" ]] && BIND_PAIRS+=("$HOME/$dir:/work/home/$dir:ro") ;;
        "") ;;
        *) echo "note: ignoring $var=$mode (expected 'rw' or 'ro')" >&2 ;;
    esac
}
_bind_agent_config CLAUDE_CONFIG .claude
_bind_agent_config GEMINI_CONFIG .gemini
_bind_agent_config CODEX_CONFIG  .codex
unset -f _bind_agent_config

# Read-only host paths, refusing bare autofs parents.
for _p in $RO_PATHS; do
    case "$_p" in
        /groups|/nrs|/scratch|/misc|/nearline|/tier2)
            echo "ERROR: '$_p' is an autofs parent; a read-only bind will NOT protect its" >&2
            echo "       nested per-lab NFS mounts. Use leaf paths, e.g. ${_p}/<lab>." >&2
            exit 1 ;;
    esac
    if [[ -d "$_p" ]]; then
        BIND_PAIRS+=("$_p:$_p:ro")
    else
        echo "note: skipping missing read-only path: $_p" >&2
    fi
done
unset _p

# ---------------------------------------------------------------------------
# ENV_PAIRS -- one "NAME=VALUE" entry per forwarded variable.
# Callers convert with:  -e "$pair"       (podman)
#                        --env "$pair"    (apptainer)
# ---------------------------------------------------------------------------
ENV_PAIRS=()
while IFS='=' read -r _name _; do
    case "$_name" in
        # FG_SERVICE_TOKEN/FG_SERVICE_PORT/FG_HOSTNAME: Fileglancer's own
        # per-job service variables (see
        # https://fileglancer-docs.janelia.org/authoring/execution/). Our
        # runnables.yaml command already uses FG_SERVICE_TOKEN as marimo's
        # real token, so forwarding it lets entrypoint.sh see and reuse the
        # same value instead of picking a different one.
        #
        # HTTP_PROXY/HTTPS_PROXY/NO_PROXY (+ lowercase): forwarded so that
        # *if* the launching shell already has an egress-restricting proxy
        # configured, it carries into the container automatically instead
        # of being silently dropped. This container has no egress
        # restriction of its own -- outbound network access is unrestricted
        # by default (see README) -- these vars only help if such a proxy
        # already exists upstream.
        ANTHROPIC_*|OPENAI_*|GEMINI_*|GOOGLE_*|*_API_KEY|*_AUTH_TOKEN|FG_SERVICE_TOKEN|FG_SERVICE_PORT|FG_HOSTNAME|HTTP_PROXY|HTTPS_PROXY|NO_PROXY|http_proxy|https_proxy|no_proxy)
            ENV_PAIRS+=("$_name=${!_name}") ;;
    esac
done < <(env)
unset _name
