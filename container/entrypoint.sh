#!/usr/bin/env bash
#
# entrypoint.sh -- runs Marimo out of a user-editable pixi environment under
# /work instead of the image's read-only baked-in one.
#
# On first run this seeds /work with a pixi project (pyproject.toml +
# pixi.lock, copied from the read-only reference at /opt/app/app) and builds
# its environment into /work/.pixi/envs/default. Because /work is the single
# writable, host bind-mounted directory, the project stays editable both from
# a shell inside the container (`pixi add <package>`) and directly on the
# host (editing ./work/pyproject.toml), without ever touching /opt/app.
#
# Marimo's own "install missing package" feature also shells out to `pixi
# add`/`pixi remove` in the current directory (see
# [tool.marimo.package_management] in the seeded pyproject.toml), so it
# targets this same project.
set -euo pipefail

# Conservative per-process resource limits (rlimits, not cgroups). Neither
# backend's native cgroup-based limits (Apptainer's --memory/--cpus/
# --pids-limit, Podman's --memory) work reliably on this host: Apptainer
# hard-fails ("cannot use cgroups - 'systemd cgroups' is not enabled in
# apptainer.conf") and Podman silently no-ops (accepts --memory, doesn't
# enforce it) under rootless/--cgroup-manager=cgroupfs -- both need an
# apptainer.conf/cgroup-v2-delegation change only Janelia IT can make. rlimits
# set here are a real, always-available fallback since they need no cgroup
# delegation, and -- set from INSIDE the container, not by wrapping the
# outer apptainer/podman launch command -- only constrain marimo/pixi/the
# agent CLIs, not the container runtime itself (wrapping the outer launch in
# `ulimit -v ...` was tested and crashed Apptainer's own Go runtime, which
# legitimately maps large virtual address space it doesn't actually use).
#
# -f (file size) and -u (max user processes/threads, the closest rlimit to
# a pids-limit) are used since they don't depend on a process's own memory-
# mapping behavior. -v/-t (virtual memory/CPU time) are deliberately left
# unset here for the same reason the outer-wrap attempt failed -- picking a
# safe number needs iterative tuning against real workloads, not a guess.
# The `resources:` block in runnables.yaml (cpus/memory/walltime) remains
# the primary control, enforced by LSF at the job level.
# ulimit -f's block size is NOT the POSIX-standard 512 bytes on this
# image -- verified empirically (/proc/<pid>/limits showed exactly double
# the intended byte count): it's 1024 here. Computed accordingly.
ulimit -f 20971520   # 20 GiB (1024-byte blocks on this image, verified)
ulimit -u 2048         # matches Podman's own --pids-limit default

cd /work

# Seed the pixi project on first run; never clobber user edits.
cp -n /opt/app/app/pyproject.toml /opt/app/app/pixi.lock . 2>/dev/null || true

# Prefer the locked, reproducible install; fall back to a fresh resolve if
# the user has hand-edited pyproject.toml without updating pixi.lock.
pixi install --manifest-path pyproject.toml --locked ||
    pixi install --manifest-path pyproject.toml

# Seed the marimo-pair Claude Code skill (vendored at /opt/app/skills, see
# container/skills/marimo-pair) as a project skill under ./.claude/skills, so
# pairing an agent CLI with the live notebook kernel works out of the box --
# no `npx skills add marimo-team/marimo-pair`, and no dependency on the
# user's own ~/.claude. `./.claude/skills` (cwd-relative) is one of the paths
# marimo's own `marimo pair prompt --claude` validation checks. Copy-if-
# absent, same as the pyproject.toml seed above, so user edits to the seeded
# copy persist across restarts.
#
# NOTE: this is NOT the same as marimo's own bundled
# marimo._server.ai.skills.marimo-pair (used internally by `marimo pair
# prompt` to build an MCP-oriented prompt) -- that copy has no scripts/ dir
# and assumes an `execute_code`/`load_capability` MCP tool this sandbox
# doesn't set up. The vendored copy here is the real, self-contained skill
# (bash + curl + jq against marimo's HTTP API) as published at
# marimo-team/marimo-pair.
SKILL_DST=".claude/skills/marimo-pair"
if [[ ! -e "$SKILL_DST" && -d /opt/app/skills/marimo-pair ]]; then
    mkdir -p "$(dirname "$SKILL_DST")"
    cp -r /opt/app/skills/marimo-pair "$SKILL_DST"
    echo ">> Installed marimo-pair Claude Code skill to ./$SKILL_DST"
fi

# Resolve the port and token marimo will actually use, so we can export
# MARIMO_URL/MARIMO_TOKEN for the marimo-pair skill (container/skills/marimo-pair)
# instead of it having to hunt for either via discovery or --no-token.
#
# Scan "$@" for an already-specified --port/--token-password -- the plain
# "marimo" Fileglancer runnable already passes both explicitly (see
# runnables.yaml, which forwards FG_SERVICE_PORT/FG_SERVICE_TOKEN) -- and
# respect them as-is rather than picking a different value.
PORT="8080"
TOKEN=""
for ((i = 1; i <= $#; i++)); do
    case "${!i}" in
        --port)              j=$((i + 1)); [[ -n "${!j:-}" ]] && PORT="${!j}" ;;
        --port=*)            PORT="${!i#--port=}" ;;
        --token-password)    j=$((i + 1)); [[ -n "${!j:-}" ]] && TOKEN="${!j}" ;;
        --token-password=*)  TOKEN="${!i#--token-password=}" ;;
    esac
done

# No caller-supplied token (e.g. a plain local `./marimo.sh` with no
# Fileglancer job wrapping it): prefer FG_SERVICE_TOKEN in case this is a
# Fileglancer job that just didn't pass --token-password itself, else fall
# back to a random token persisted under /work so local restarts reuse the
# same value instead of a fresh, undiscoverable one every time (same idiom
# https-wrap.sh already uses to persist its self-signed cert). Passed to
# marimo explicitly rather than left to its own hidden default, so the
# token is always known here.
_extra_args=()
if [[ -z "$TOKEN" ]]; then
    if [[ -n "${FG_SERVICE_TOKEN:-}" ]]; then
        TOKEN="$FG_SERVICE_TOKEN"
    elif [[ -f .marimo-token ]]; then
        TOKEN="$(cat .marimo-token)"
    else
        TOKEN="$(openssl rand -hex 16)"
        printf '%s' "$TOKEN" > .marimo-token
    fi
    _extra_args+=(--token-password "$TOKEN")
fi

export MARIMO_TOKEN="$TOKEN"
export MARIMO_URL="http://127.0.0.1:${PORT}"

# Let a separately-launched shell (container/*/shell.sh, a fresh container
# instance) pick these up too -- the `export` above only reaches marimo's
# own process tree, not a sibling container sharing the same /work.
cat > .marimo-pair.env <<ENVEOF
MARIMO_TOKEN=$MARIMO_TOKEN
MARIMO_URL=$MARIMO_URL
ENVEOF

exec pixi run --manifest-path pyproject.toml \
    marimo edit / --headless --host 0.0.0.0 --port 8080 "${_extra_args[@]}" "$@"
