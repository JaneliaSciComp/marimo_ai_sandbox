#!/usr/bin/env bash
#
# common.sh -- sourced by start.sh, shell.sh, run_podman.sh, shell_podman.sh.
# Not meant to be executed directly.
#
# Reads (uses defaults if unset):
#   WORK, PORT, RO_PATHS
#
# Sets:
#   WORK, PORT, RO_PATHS
#   BIND_PAIRS  -- "src:dst[:options]" strings; callers prefix with -v or --bind
#   ENV_PAIRS   -- "NAME=VALUE" strings;        callers prefix with -e or --env
#
# Side-effects:
#   Creates $WORK/home and $WORK/tmp.
#   Seeds $WORK with starter notebooks on first run.

# Scripts cd to their own directory before sourcing this file, so $PWD is
# container/apptainer/ or container/podman/.  The project root is two levels up.
_PROJECT_ROOT="$(cd "$PWD/../.." && pwd)"

# Load conf/config.toml if present, setting WORK, PORT, RO_PATHS from it
# (only when not already set in the environment).
_CONFIG="$_PROJECT_ROOT/conf/config.toml"
if [[ -f "$_CONFIG" ]]; then
    _toml_work="$(python3 -c "
import tomllib, sys
with open('$_CONFIG', 'rb') as f:
    d = tomllib.load(f)
print(d.get('work', ''))
" 2>/dev/null)"
    _toml_port="$(python3 -c "
import tomllib, sys
with open('$_CONFIG', 'rb') as f:
    d = tomllib.load(f)
print(d.get('port', ''))
" 2>/dev/null)"
    _toml_ro="$(python3 -c "
import tomllib, sys
with open('$_CONFIG', 'rb') as f:
    d = tomllib.load(f)
print(' '.join(d.get('ro_paths', [])))
" 2>/dev/null)"
    [[ -n "$_toml_work" ]] && WORK="${WORK:-$_toml_work}"
    [[ -n "$_toml_port" ]] && PORT="${PORT:-$_toml_port}"
    [[ -n "$_toml_ro"   ]] && RO_PATHS="${RO_PATHS:-$_toml_ro}"
    unset _toml_work _toml_port _toml_ro
fi
unset _CONFIG

WORK="${WORK:-$_PROJECT_ROOT/work}"
PORT="${PORT:-8080}"
unset _PROJECT_ROOT

# Default read-only paths: leaf NFS mounts that exist on this host.
# See READ-ONLY CAVEAT in start.sh -- bare autofs parents must not be used.
if [[ -z "${RO_PATHS+set}" ]]; then
    _default_ro=""
    for _d in /groups/scicompsoft /nrs/scicompsoft; do
        [[ -d "$_d" ]] && _default_ro="$_default_ro $_d"
    done
    RO_PATHS="$_default_ro"
    unset _default_ro _d
fi

# Prepare the writable work dir.
mkdir -p "$WORK"/home "$WORK"/tmp

# Seed the work dir with starter notebooks on first run.
if [[ -d ../app ]] && ! compgen -G "$WORK/*.py" >/dev/null; then
    cp -n ../app/*.py "$WORK"/ 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# BIND_PAIRS -- one "src:dst[:options]" entry per mount.
# Callers convert with:  -v "$pair"       (podman)
#                        --bind "$pair"   (apptainer)
# ---------------------------------------------------------------------------
BIND_PAIRS=("$WORK:/work:rw")

# Agent credential dirs -- shared so tools inside the container are logged in.
[[ -d "$HOME/.claude" ]] && BIND_PAIRS+=("$HOME/.claude:/work/home/.claude")
[[ -d "$HOME/.gemini" ]] && BIND_PAIRS+=("$HOME/.gemini:/work/home/.gemini")
[[ -d "$HOME/.codex"  ]] && BIND_PAIRS+=("$HOME/.codex:/work/home/.codex")

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
        ANTHROPIC_*|OPENAI_*|GEMINI_*|GOOGLE_*|*_API_KEY|*_AUTH_TOKEN)
            ENV_PAIRS+=("$_name=${!_name}") ;;
    esac
done < <(env)
unset _name
