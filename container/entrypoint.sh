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

exec pixi run --manifest-path pyproject.toml \
    marimo edit / --headless --host 0.0.0.0 --port 8080 "$@"
