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

exec pixi run --manifest-path pyproject.toml \
    marimo edit / --headless --host 0.0.0.0 --port 8080 "$@"
