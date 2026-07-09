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
pixi.toml / pixi.lock         Agent-CLI-runtime env baked into the image (nodejs, uv, git, ...)
app/pyproject.toml / pixi.lock  Seed for the user-editable Marimo/Python env (see below)
entrypoint.sh                 Seeds + installs the pixi env under /work, then serves Marimo
marimo.def                    Apptainer build recipe (installs everything at build time)
Containerfile                 Podman/Docker build recipe
build.sh / build_podman.sh    build scripts (for Apptainer or Podman image)
start.sh / run_podman.sh        serve Marimo with the read-only sandbox model
shell.sh / shell_podman.sh    interactive shell in the sandbox (drive the agent CLIs)
app/agents_demo.py            starter Marimo notebook that calls an agent via subprocess
work/                         runtime writable dir (created on first run; git-ignored)
```

## Build

Building from source is **optional**. `./start.sh` (Apptainer) and
`./marimo.sh` (Podman) both default to pulling the pre-built image published
by `.github/workflows/publish-image.yml` at
`ghcr.io/janeliascicomp/marimo_ai_sandbox:latest` (Apptainer converts it to a
local `.sif` on first use) instead of building locally, falling back to a
local build only if the pull fails and no local image/`.sif` exists yet. Use
the steps below if you want to build from source anyway -- e.g. to test an
unpublished change, or on a host without egress to ghcr.io.

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

### HTTPS (optional)

Marimo has no built-in TLS support, so `pixi run marimo-https` fronts the
same launch flow with a local [Caddy](https://caddyserver.com/) reverse
proxy:

```bash
pixi run marimo-https                 # serves https://<host>:8443 -> internal :8080
```

Caddy terminates TLS using a self-signed certificate that the wrapper script
generates itself (via `openssl`) and hands to Caddy as a static cert file,
rather than Caddy's own internal-CA issuer — that issuer's first run tries to
install its CA root into the OS trust store via `sudo`, which hangs/fails on
a host with no interactive sudo session (e.g. a compute node). The cert is
stored in the work directory (`https-cert/marimo-https.crt`) and reused
across restarts instead of being regenerated (it's only regenerated if the
hostname changes, e.g. a new compute-node allocation). On startup the script
prints the cert's path; install it in your browser's trust store to avoid
the untrusted-certificate warning (Chrome: Settings → Privacy and security →
Security → Manage certificates → Authorities → Import; Firefox: Settings →
Privacy & Security → Certificates → View Certificates → Authorities →
Import). This is entirely self-contained — it doesn't depend on Fileglancer
to obtain a cert.

### Read-only model

`start.sh` launches the container with `--contain` (host home and CWD are NOT
mounted; `/tmp` is a private tmpfs) and then:

- bind-mounts each path in `RO_PATHS` **read-only**;
- binds `./work` → `/work` **read-write** (override with `WORK=/path` or `--work /path`);
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
> `WORK` and `PORT` accept the same treatment (`--work`/`--port` flags, or
> the 2nd/3rd positional pixi task arguments — pass `""` to skip one and set
> a later one, e.g. `pixi run marimo "" "" 9999` for just the port). CLI
> flags / pixi task arguments take precedence over the env vars, which take
> precedence over `conf/config.toml`.
>
> Verified: binding `/groups/scicompsoft:ro` makes writes there fail
> (`Read-only file system`), while binding the parent `/groups:ro` does not.

## Python / Marimo environment

Marimo, Python, and the data-science packages (numpy, pandas, polars, altair)
run out of a **user-editable pixi environment**, not the read-only image.
`container/app/pyproject.toml` + `pixi.lock` are the seed for this project;
on first run they're copied into `./work` (the one writable, host-visible
directory) and installed into `./work/.pixi`. `container/entrypoint.sh` then
serves Marimo from that environment instead of anything baked into the
image.

Because `./work` is a real directory on the host, the project is editable
two ways:

- **From inside the container** — Marimo's own "install missing package"
  prompt (and a shell's `pixi add <package>` / `pixi remove <package>`) act
  on this project, since `[tool.marimo.package_management] manager = "pixi"`
  is set in the seeded `pyproject.toml`.
- **From the host** — edit `./work/pyproject.toml` directly and re-run
  `pixi run marimo ...`; the next container start reinstalls it.

Once seeded, `./work/pyproject.toml` is never overwritten automatically (so
your edits persist); delete it (and `./work/pixi.lock`, `./work/.pixi`) to
reseed from the image's current version.

`entrypoint.sh` also seeds the [`marimo-pair`](https://marimo.io/blog/marimo-pair)
Claude Code skill (vendored at `container/skills/marimo-pair`, from
[marimo-team/marimo-pair](https://github.com/marimo-team/marimo-pair),
Apache-2.0 -- see the `LICENSE` file alongside it -- baked into the image)
into `./work/.claude/skills/marimo-pair`, so an agent CLI can pair-program
against the live notebook kernel with no extra setup and no network fetch at
runtime. This is a *project* skill: it's only picked up by an agent CLI whose
working directory is `/work` (the notebook's own embedded terminal, or a
shell started via `./shell.sh` after `cd /work`). Its `reference/finding-marimo.md`
has been locally modified to point directly at this sandbox's pixi-managed
Python environment (`/work/pyproject.toml`) instead of the generic
uv/global/sandbox decision tree.

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
- **HTTPS:** plain `marimo`/`start.sh` serve HTTP only. Use `pixi run
  marimo-https` for a locally TLS-terminated option (see above); its
  self-signed cert requires installing the printed CA cert to avoid browser
  warnings.
