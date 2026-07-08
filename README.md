# Marimo AI Sandbox

A reproducible [Apptainer](https://apptainer.org/) container that runs a
[Marimo](https://marimo.io/) reactive-notebook server with a Python environment
built by [pixi](https://pixi.sh/), and bundles four AI coding-agent CLIs plus
their ACP adapters:

| CLI | Agent | Install source | ACP |
|-----|-------|----------------|-----|
| `claude` | Claude Code | `@anthropic-ai/claude-code` (npm) | adapter: `@zed-industries/claude-code-acp` |
| `codex` | OpenAI Codex | `@openai/codex` (npm) | adapter: `@zed-industries/codex-acp` |
| `gemini` | Gemini CLI | `@google/gemini-cli` (npm) | **native** (`gemini --acp`) |
| `agy` | Antigravity | native Go binary from `antigravity.google` | not yet |

The container is a **read-only sandbox**: the host filesystem is mounted
read-only so agents and notebooks can *read* code and data but cannot mutate the
host. Exactly one writable directory (`./work` → `/work`) holds Marimo notebooks
and any files the agents create.

## Layout

```
pixi.toml / pixi.lock         Python environment (python, marimo, nodejs, uv, git, ...)
marimo.def                    Apptainer build recipe (installs everything at build time)
Containerfile                 Podman/Docker build recipe
build.sh / build_podman.sh    build scripts (for Apptainer or Podman image)
start.sh / run_podman.sh        serve Marimo with the read-only sandbox model
shell.sh / shell_podman.sh    interactive shell in the sandbox (drive the agent CLIs)
app/agents_demo.py            starter Marimo notebook that calls an agent via subprocess
work/                         runtime writable dir (created on first run; git-ignored)
```

## Build

### Apptainer Build

Requires network access and unprivileged build support (`--fakeroot`). On
Janelia HPC, run on a node where `apptainer build --fakeroot` is permitted, or
build elsewhere and copy the `.sif` over.

```bash
pixi install        # generates / refreshes pixi.lock (already committed)
./build.sh          # -> marimo_sandbox.sif
```

### Podman Build

For Podman support:

```bash
pixi install
./build_podman.sh   # -> builds marimo_sandbox:latest
```

## Run the Marimo server

```bash
# Provide whichever API keys you need (forwarded automatically):
export ANTHROPIC_API_KEY=sk-...
export OPENAI_API_KEY=sk-...
export GEMINI_API_KEY=...          # or GOOGLE_API_KEY

./start.sh                            # serves http://<host>:8080 (Apptainer)
# or
./run_podman.sh                     # serves http://<host>:8080 (Podman)
```

Open the printed URL (with the access token) in a browser. The notebook
`app/agents_demo.py` is copied into `./work` on first run.

### Read-only model

`start.sh` launches the container with `--contain` (host home and CWD are NOT
mounted; `/tmp` is a private tmpfs) and then:

- bind-mounts each path in `RO_PATHS` **read-only**;
- binds `./work` → `/work` **read-write** (override with `WORK=/path`);
- sets `HOME=/work/home` (via `--home`, the only mechanism that works —
  apptainer refuses to set `HOME` via `--env`) and `TMPDIR=/work/tmp`, so
  Marimo notebooks live in `/work` and agent config/cache (`~/.claude`,
  `~/.codex`, ...) persist under `./work/home`;
- leaves the container rootfs itself read-only.

So an agent can read anything under the bound read-only paths but can only write
into `/work`. Attempts to modify the host filesystem fail by design.

> **⚠️ Read-only caveat on Janelia (autofs + NFS).** `/groups`, `/nrs` and
> `/scratch` are autofs parents with a **separate NFS mount per lab**. A
> read-only bind is **not recursive**, so binding `"/groups:ro"` leaves the
> nested per-lab NFS mounts **writable** — a silent leak that defeats the
> sandbox. You must bind the **leaf** per-lab paths instead, e.g.
> `/groups/scicompsoft`. `start.sh`/`shell.sh` **default `RO_PATHS` to your lab
> dirs** (`/groups/scicompsoft`, `/nrs/scicompsoft`) and **refuse** bare autofs
> parents. Set your own with `RO_PATHS="/groups/<lab> /nrs/<lab> ..."`, or
> equivalently:
> ```bash
> ./start.sh --ro-paths "/groups/<lab> /nrs/<lab> ..."
> pixi run marimo "/groups/<lab> /nrs/<lab> ..."
> ```
> (The `--ro-paths` CLI flag / pixi task argument takes precedence over the
> `RO_PATHS` env var and `conf/config.toml`.)
>
> Verified: binding `/groups/scicompsoft:ro` makes writes there fail
> (`Read-only file system`), while binding the parent `/groups:ro` does not.

## Interactive / terminal use

```bash
./shell.sh          # Apptainer
# or
./shell_podman.sh   # Podman

# then, inside the container:
claude -p "summarize this project"
codex exec "..."
gemini -p "..."
agy -p "..."
```

## Credentials

Credentials are **never baked into the image**. Any host env var matching
`ANTHROPIC_*`, `OPENAI_*`, `GEMINI_*`, `GOOGLE_*`, `*_API_KEY`, or `*_AUTH_TOKEN`
is forwarded into the container by `start.sh` / `shell.sh`.

## ACP (Agent Client Protocol)

To drive these agents from an external ACP client (e.g. Zed):

- **Claude Code:** `npx --prefix /opt/npm-global claude-code-acp` (the
  `@zed-industries/claude-code-acp` adapter on PATH).
- **Codex:** `@zed-industries/codex-acp` adapter.
- **Gemini:** `gemini --acp` (native, no adapter needed).
- **Antigravity:** no ACP support yet.

## Notes & caveats

- **Antigravity self-update:** `agy` tries to self-update in the background; on
  the read-only rootfs that write fails harmlessly. `DISABLE_AUTOUPDATER=1` is
  set in the image to suppress it.
- **Tool versions** are pinned only loosely (`*`) in `pixi.toml` for conda
  packages and unpinned for npm packages, so rebuilding picks up upstream
  updates. Pin them if you need byte-for-byte reproducibility.
- **Marimo auth:** `marimo edit` prints a per-session access token; use it (or
  `--token-password`) when exposing the port beyond localhost.
