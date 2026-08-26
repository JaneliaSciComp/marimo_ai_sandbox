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
#   ENABLE_BSUB -- "1" to enable the sandboxed bsub wrapper (see
#   container/bsub-wrapper/bin/bsub); default unset/off.
#
# Also accepts on the caller's "$@" (highest precedence, overrides the env
# var and conf/config.toml; consumed here, remaining args are left in "$@"
# for the caller to forward on):
#   --ro-paths PATHS   or   --ro-paths=PATHS   (space-separated, same format as RO_PATHS)
#   --work PATH        or   --work=PATH
#   --port PORT        or   --port=PORT
#   --enable-bsub                              (no value; same as ENABLE_BSUB=1)
#
# Sets:
#   WORK, PORT, RO_PATHS, ENABLE_BSUB
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
        --enable-bsub)
            ENABLE_BSUB=1
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
ENABLE_BSUB="${ENABLE_BSUB:-0}"

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
# HAS_GPU -- whether to pass GPU-passthrough flags to this backend's launch
# command (apptainer's --nv / podman's --device nvidia.com/gpu=all -- see
# marimo.sh/shell.sh in each backend dir). Detected at launch time rather
# than assumed, so the exact same command works unchanged on GPU and
# non-GPU nodes: `nvidia-smi -L` (vs. a bare `nvidia-smi`) fails fast and
# silently if no driver/GPU is present, instead of nvidia-smi's multi-line
# table on success.
# ---------------------------------------------------------------------------
HAS_GPU=0
if command -v nvidia-smi &>/dev/null && nvidia-smi -L &>/dev/null; then
    HAS_GPU=1
fi

# ---------------------------------------------------------------------------
# Sandboxed bsub wrapper (off by default -- see container/bsub-wrapper/bin/
# bsub, always on PATH inside the image but a no-op without this). Enabling
# it bind-mounts the real LSF client (a single autofs leaf, like the RO_PATHS
# check above) and forwards the LSF_*/EGO_*/LSB_* env vars bsub itself needs
# to talk to the cluster -- none of which are forwarded otherwise.
# ---------------------------------------------------------------------------
if [[ "$ENABLE_BSUB" == "1" ]]; then
    LSF_BINDIR="${LSF_BINDIR:-}"
    if [[ -z "$LSF_BINDIR" || ! -d "/misc/lsf" ]]; then
        echo "ERROR: --enable-bsub requires LSF's own environment (LSF_BINDIR unset, or" >&2
        echo "       /misc/lsf missing) -- run this from a shell with LSF already loaded." >&2
        exit 1
    fi
    # $WORK must be visible from whatever OTHER node LSF schedules a
    # wrapped job onto -- /scratch is node-local (see the RO_PATHS autofs
    # comment above for the general caveat), so the child job's re-entry
    # script (written into $WORK below by the caller) would be invisible
    # there. /groups and /nrs are the real, cluster-wide NFS mounts.
    case "$WORK" in
        /scratch/*)
            echo "ERROR: --enable-bsub needs \$WORK on shared storage (/groups or /nrs)," >&2
            echo "       not /scratch, which is local to this node only: $WORK" >&2
            exit 1 ;;
    esac
    BIND_PAIRS+=("/misc/lsf:/misc/lsf:ro")
fi

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
        # LSF/EGO's own client env vars -- only forwarded when the bsub
        # wrapper block above actually bind-mounted /misc/lsf; otherwise
        # these would just point at paths that don't exist in the
        # container. LD_LIBRARY_PATH is included here since real bsub
        # needs LSF_LIBDIR on it to run at all.
        LSF_*|EGO_*|LSB_*|LD_LIBRARY_PATH)
            [[ "$ENABLE_BSUB" == "1" ]] && ENV_PAIRS+=("$_name=${!_name}") ;;
    esac
done < <(env)
unset _name

[[ "$ENABLE_BSUB" == "1" ]] && ENV_PAIRS+=("BSUB_WRAPPER_ENABLED=1")

# ---------------------------------------------------------------------------
# write_bsub_runner_apptainer/_podman -- generate $WORK/.bsub-wrapper-runner.sh,
# the script container/bsub-wrapper/bin/bsub execs a wrapped job's command
# through. Called by each backend's marimo.sh/shell.sh (after they've built
# their own BIND_ARGS/ENV_ARGS) when $ENABLE_BSUB == 1, so the re-entered
# job on whatever node LSF picks gets the exact same binds/env this
# container itself was launched with. Not called at all when bsub isn't
# enabled, so the file is simply never written.
# ---------------------------------------------------------------------------
write_bsub_runner_apptainer() {
    local sif="$1" runner="$WORK/.bsub-wrapper-runner.sh" sif_abs a
    # readlink -f: $sif is relative to the caller's own dir; the runner
    # needs an absolute path since it may run with a different CWD, on a
    # different node, via the real bsub.
    sif_abs="$(readlink -f "$sif")"
    {
        echo "#!/usr/bin/env bash"
        printf 'exec apptainer exec --contain --cleanenv --pid --home %q --env %q' \
            "$WORK/home:/work/home" "TMPDIR=/work/tmp"
        for a in "${BIND_ARGS[@]}" "${ENV_ARGS[@]}" "$sif_abs"; do printf ' %q' "$a"; done
        printf ' "$@"\n'
    } > "$runner"
    chmod +x "$runner"
}

write_bsub_runner_podman() {
    local image="$1" runner="$WORK/.bsub-wrapper-runner.sh" a
    {
        echo "#!/usr/bin/env bash"
        # --entrypoint "": run the given command directly, bypassing the
        # image's own ENTRYPOINT (entrypoint.sh, which starts Marimo) --
        # same idea as apptainer exec vs. run above.
        printf 'exec podman run --rm --read-only --tmpfs /tmp --tmpfs /run --cgroup-manager=cgroupfs --events-backend=file --net=host --entrypoint %q -e %q -e %q -w /work' \
            "" "HOME=/work/home" "TMPDIR=/work/tmp"
        for a in "${BIND_ARGS[@]}" "${ENV_ARGS[@]}" "$image"; do printf ' %q' "$a"; done
        printf ' "$@"\n'
    } > "$runner"
    chmod +x "$runner"
}
