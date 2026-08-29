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
#   KEEP_ID -- "1" to run the Podman backend's container as your real host
#   uid/gid (--userns=keep-id --user "$(id -u):$(id -g)") instead of root
#   mapped through the user namespace; default unset/off. Requires an
#   /etc/subuid//etc/subgid range for your account (see README's "Podman
#   Build" prerequisite note) -- Podman errors out plainly if you don't have
#   one. No-op on the Apptainer backend, which already runs as your real
#   identity by default with no separate flag needed.
#   ALLOW_HOSTS -- space-separated hostnames allowed through the opt-in
#   network egress allowlist (both backends' marimo.sh/shell.sh); default
#   unset, i.e. no allowlist -- those scripts keep their existing
#   unrestricted egress. See network_allowlist_proxy_start below, and
#   container/{podman,apptainer}/lib.sh for the per-backend wiring.
#
# Also accepts on the caller's "$@" (highest precedence, overrides the env
# var and conf/config.toml; consumed here, remaining args are left in "$@"
# for the caller to forward on):
#   --ro-paths PATHS   or   --ro-paths=PATHS   (space-separated, same format as RO_PATHS)
#   --ro-path-1 PATH   or   --ro-path-1=PATH   (single-directory slots, for
#   --ro-path-2 PATH   or   --ro-path-2=PATH   Fileglancer's directory picker
#   --ro-path-3 PATH   or   --ro-path-3=PATH   -- see below)
#   --work PATH        or   --work=PATH
#   --port PORT        or   --port=PORT
#   --enable-bsub                              (no value; same as ENABLE_BSUB=1)
#   --keep-id                                  (no value; same as KEEP_ID=1)
#   --allow HOST       or   --allow=HOST       (repeatable; same format as ALLOW_HOSTS)
#
# Sets:
#   WORK, PORT, RO_PATHS, ENABLE_BSUB, KEEP_ID, ALLOW_HOSTS
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
        --ro-path-[0-9])
            [[ -n "${2:-}" ]] && _RO_PATH_SLOTS="${_RO_PATH_SLOTS:-}${_RO_PATH_SLOTS:+ }$2"
            shift 2
            ;;
        --ro-path-[0-9]=*)
            _val="${1#--ro-path-*=}"
            [[ -n "$_val" ]] && _RO_PATH_SLOTS="${_RO_PATH_SLOTS:-}${_RO_PATH_SLOTS:+ }$_val"
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
        --keep-id)
            KEEP_ID=1
            shift
            ;;
        --allow)
            if [[ -z "${2:-}" ]]; then
                echo "ERROR: --allow requires a hostname argument" >&2
                exit 1
            fi
            ALLOW_HOSTS="${ALLOW_HOSTS:-}${ALLOW_HOSTS:+ }$2"
            shift 2
            ;;
        --allow=*)
            _val="${1#--allow=}"
            [[ -n "$_val" ]] && ALLOW_HOSTS="${ALLOW_HOSTS:-}${ALLOW_HOSTS:+ }$_val"
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

# --ro-path-1/2/3 (Fileglancer's directory-picker slots) are always additive
# on top of RO_PATHS, however RO_PATHS itself got set (env var,
# conf/config.toml, or --ro-paths) -- not order-dependent on where the flags
# land on the command line, unlike the plain overwrite-if-given precedence
# used for --ro-paths/--work/--port above.
if [[ -n "${_RO_PATH_SLOTS:-}" ]]; then
    RO_PATHS="${RO_PATHS:-}${RO_PATHS:+ }$_RO_PATH_SLOTS"
fi
unset _RO_PATH_SLOTS

WORK="${WORK:-$_PROJECT_ROOT/work}"
PORT="${PORT:-8080}"
unset _PROJECT_ROOT

# A relative WORK (from --work/env/config.toml) is resolved against the
# caller's original directory, not this script's own dir (the callers cd
# there before sourcing this file) -- otherwise e.g. `--work foobar` run
# from the project root would silently land in container/apptainer/foobar.
[[ "$WORK" != /* ]] && WORK="${_CALLER_PWD:-$PWD}/$WORK"

RO_PATHS="${RO_PATHS:-}"
ENABLE_BSUB="${ENABLE_BSUB:-0}"
KEEP_ID="${KEEP_ID:-0}"
ALLOW_HOSTS="${ALLOW_HOSTS:-}"

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
# check above) and forwards the LSF_*/EGO_* env vars bsub itself needs
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
        # LSF/EGO's own CLIENT config vars (where its binaries/libs/conf
        # live) -- only forwarded when the bsub wrapper block above
        # actually bind-mounted /misc/lsf. Deliberately LSF_*/EGO_* only,
        # NOT LSB_*: the LSB_* vars are the CURRENT job's own runtime
        # context (this shell may itself be inside a job), not something a
        # freshly-submitted job should inherit, and several of them (e.g.
        # LSB_SUB_RES_REQ="rusage[mem=15360,]") contain commas/brackets
        # that break Apptainer's --env flag (it parses its argument as a
        # key=value CSV map, not a literal string). LD_LIBRARY_PATH is
        # included since real bsub needs LSF_LIBDIR on it to run at all.
        LSF_*|EGO_*|LD_LIBRARY_PATH)
            [[ "$ENABLE_BSUB" == "1" ]] && ENV_PAIRS+=("$_name=${!_name}") ;;
    esac
done < <(env)
unset _name

if [[ "$ENABLE_BSUB" == "1" ]]; then
    ENV_PAIRS+=("BSUB_WRAPPER_ENABLED=1")
    # $WORK here is the REAL HOST path (e.g. /groups/lab/...), not the
    # in-container "/work" it's bound to. The wrapper checks the runner
    # script exists via the in-container path (its own default,
    # /work/...) but must hand bsub the HOST path instead: a submitted
    # job starts out running bare-metal on the exec host's filesystem,
    # before any container exists there, so "/work/..." wouldn't resolve.
    ENV_PAIRS+=("BSUB_WRAPPER_RUNNER_HOST=$WORK/.bsub-wrapper-runner.sh")
fi

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

# KNOWN ISSUE (see README's "Submitting LSF jobs" section): LSF's eauth
# fails inside a rootless Podman container ("External authentication
# failed") -- confirmed independent of UID mapping, capabilities, and the
# SSSD/KCM sockets tried so far. Hard-error here (consistent with the
# other --enable-bsub misconfiguration checks above: missing /misc/lsf,
# $WORK under /scratch) rather than let every `bsub` call inside the
# container hit this cryptic error at submission time. A working
# runner-generator implementation (mirroring write_bsub_runner_apptainer,
# plus the Janelia podman storage-redirect setup a standalone job needs)
# existed at this commit's parent in git history, if eauth is ever
# root-caused and this needs re-enabling.
write_bsub_runner_podman() {
    echo "ERROR: --enable-bsub is not supported on the Podman backend -- LSF's eauth" >&2
    echo "       (Kerberos via sssd-kcm) fails inside a rootless Podman container." >&2
    echo "       Verified working on Apptainer only; see README." >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Network egress allowlist (opt-in, shared by both backends) -- adapted from
# JaneliaScientificComputingSystems/agentic-sandbox's
# allowlist_proxy.py/relay.py (vendored at container/, stdlib-only Python,
# unmodified). Off by default: both backends keep their existing
# unrestricted egress unless $ALLOW_HOSTS is set (via --allow, repeatable).
# Only the container-launch flag syntax (network-isolation flag, bind-mount
# syntax, command-override mechanics) differs per backend -- see
# container/podman/lib.sh and container/apptainer/lib.sh for those.
# ---------------------------------------------------------------------------

# Always allowed once the allowlist is active at all, on top of whatever
# $ALLOW_HOSTS adds -- container/entrypoint.sh's first-run `pixi install`
# (seeding the user-editable Python/marimo env into /work, see README's
# "Python / Marimo environment" section) needs conda-forge to succeed no
# matter what a task itself needs allowed. Confirmed live: a --allow list
# that didn't include this failed the very first `pixi install` with
# `client error (Connect)` fetching packages from conda.anaconda.org,
# before the task's own command ever ran.
NETWORK_ALLOWLIST_BASELINE_HOSTS="conda.anaconda.org"

# network_allowlist_proxy_start -- starts the host-side allowlist_proxy.py
# on a fresh Unix socket, if $ALLOW_HOSTS is non-empty. All output vars are
# left empty (a no-op) otherwise.
#
# The socket lives inside a private (mode 0700) temp directory created with
# `mktemp -d`, not `mktemp -u` on the socket path directly -- `-u` only
# prints a name it thinks is free, with no exclusive creation, so a
# concurrent process (or an attacker in a world-writable /tmp) can win the
# race and create that path first. Also fails fast (clear error + exit 1,
# with the proxy's own log printed) if allowlist_proxy.py dies immediately
# instead of silently continuing with a broken, unenforced "allowlist".
#
# Sets:
#   NETWORK_SCRIPTS_DIR -- container/, where allowlist_proxy.py/relay.py
#                          live. Resolved from THIS FILE's own location
#                          (via BASH_SOURCE), not the caller's cwd -- both
#                          backend scripts cd into their own subdirectory
#                          before sourcing common.sh.
#   NETWORK_PROXY_PID    -- host-side allowlist_proxy.py's PID, or "" if unused
#   NETWORK_PROXY_SOCK   -- its Unix socket path, or "" if unused
#   NETWORK_PROXY_DIR    -- the private temp dir NETWORK_PROXY_SOCK lives in
#                          (removed wholesale by
#                          network_allowlist_proxy_cleanup), or "" if unused
#   NETWORK_RELAY_PORT   -- the in-container relay's TCP port, or "" if unused
network_allowlist_proxy_start() {
    NETWORK_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    NETWORK_PROXY_PID=""
    NETWORK_PROXY_SOCK=""
    NETWORK_PROXY_DIR=""
    NETWORK_RELAY_PORT=""
    [[ -z "${ALLOW_HOSTS// /}" ]] && return 0

    NETWORK_PROXY_DIR="$(mktemp -d /tmp/sandbox-proxy.XXXXXX)"
    NETWORK_PROXY_SOCK="$NETWORK_PROXY_DIR/proxy.sock"
    # Deliberately a bare `python3` from PATH, NOT the pixi-managed one this
    # file's _CONFIG/tomllib section above insists on -- that concern was
    # specifically about tomllib needing Python 3.11+, and about a Python
    # that's only guaranteed to exist AFTER a container has started and
    # entrypoint.sh has seeded $WORK/.pixi. allowlist_proxy.py needs neither:
    # it's stdlib asyncio only (works on any Python 3.x), and it has to be
    # running on the HOST *before* any container starts (the container
    # bind-mounts its socket in) -- at that point $WORK/.pixi may not exist
    # yet at all (a genuinely first-ever run), so it can't be the Python
    # relied on here. A bare system python3 is what
    # agentic-sandbox's own allowlist_proxy.py assumes too.
    # shellcheck disable=SC2086 -- both vars are space-separated lists,
    # intentionally word-split into multiple allowlist_proxy.py arguments.
    python3 "$NETWORK_SCRIPTS_DIR/allowlist_proxy.py" "$NETWORK_PROXY_SOCK" \
        $NETWORK_ALLOWLIST_BASELINE_HOSTS $ALLOW_HOSTS \
        > "$NETWORK_PROXY_DIR/proxy.log" 2>&1 &
    NETWORK_PROXY_PID=$!
    sleep 1
    if ! kill -0 "$NETWORK_PROXY_PID" 2>/dev/null; then
        echo "ERROR: allowlist_proxy.py failed to start -- log:" >&2
        cat "$NETWORK_PROXY_DIR/proxy.log" >&2
        rm -rf "$NETWORK_PROXY_DIR"
        exit 1
    fi
    NETWORK_RELAY_PORT=$((20000 + RANDOM % 20000))
}

# network_allowlist_proxy_cleanup -- stop the host-side proxy (if any) and
# remove its private temp dir (socket + log). No-op when the allowlist was
# never enabled.
network_allowlist_proxy_cleanup() {
    [[ -n "${NETWORK_PROXY_PID:-}" ]] && kill "$NETWORK_PROXY_PID" 2>/dev/null
    [[ -n "${NETWORK_PROXY_DIR:-}" && -e "$NETWORK_PROXY_DIR" ]] && rm -rf "$NETWORK_PROXY_DIR"
    return 0
}

# network_allowlist_inner_wrap -- the in-container wrapper command that
# starts the relay and exports http_proxy/https_proxy before exec'ing
# through to the real command. Only meaningful once
# network_allowlist_proxy_start has set NETWORK_RELAY_PORT (i.e. ALLOW_HOSTS
# was non-empty) -- callers check that themselves before using this.
#
# Sets: NETWORK_INNER_WRAP -- array ("-c" "<script>" "bash"), meant to be
# invoked as the container's command with /bin/bash as the entrypoint/exec
# target, followed by the real command and its args, e.g.:
#   podman run --entrypoint /bin/bash ... "$IMAGE" "${NETWORK_INNER_WRAP[@]}" <real cmd...>
#   apptainer exec ... "$SIF" /bin/bash "${NETWORK_INNER_WRAP[@]}" <real cmd...>
network_allowlist_inner_wrap() {
    NETWORK_INNER_WRAP=(
        -c
        'python3 /opt/relay.py 127.0.0.1 '"$NETWORK_RELAY_PORT"' /run/proxy.sock &
         sleep 1
         export http_proxy=http://127.0.0.1:'"$NETWORK_RELAY_PORT"' https_proxy=http://127.0.0.1:'"$NETWORK_RELAY_PORT"'
         exec "$@"'
        bash
    )
}
