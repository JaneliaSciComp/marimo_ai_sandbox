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
pixi.toml / pixi.lock                 Agent-CLI-runtime env baked into the image (nodejs, uv, git, ...)
container/common.sh                   shared bash lib: WORK/PORT/RO_PATHS/ALLOW_HOSTS, binds, GPU detection, bsub setup
container/entrypoint.sh               Seeds + installs the pixi env under /work, then serves Marimo
container/apptainer/marimo.def        Apptainer build recipe (installs everything at build time)
container/apptainer/{build,marimo,shell}.sh   Apptainer build / serve / interactive-shell scripts
container/apptainer/lib.sh            Apptainer-only: wires the shared network allowlist below
container/podman/Containerfile        Podman/Docker build recipe
container/podman/{build,marimo,shell}.sh      Podman build / serve / interactive-shell scripts
container/podman/lib.sh               Podman-only hardening: storage isolation/staleness recovery,
                                       catatonit watchdog, plus wiring the shared network allowlist
container/allowlist_proxy.py / relay.py   the network allowlist mechanism itself, shared by both
                                       backends (see "Sandbox strength" below)
container/bsub-wrapper/bin/bsub       opt-in bsub wrapper -- see "Submitting LSF jobs" below
container/app/AGENTS.md               seeded into /work; CLAUDE.md/GEMINI.md symlink to it
container/app/agents_demo.py          starter Marimo notebook that calls an agent via subprocess
container/caddy-lib.sh                shared Caddy/TLS-cert helpers used by https-wrap.sh and
                                       terminal-wrap.sh
container/https-wrap.sh               fronts Marimo with Caddy TLS -- see "HTTPS (optional)" below
container/terminal-wrap.sh            fronts a web terminal (ttyd) with Caddy TLS, an alternative
                                       to Marimo -- see "Web terminal" below
runnables.yaml                        Fileglancer app manifest: "Marimo AI Sandbox" (marimo-https,
                                       marimo-podman-https -- HTTPS-only, see "HTTPS (optional)"
                                       below)
terminal/runnables.yaml               Separate Fileglancer app manifest: "Marimo AI Sandbox - Web
                                       Terminal" (terminal-https, terminal-podman-https -- see "Web
                                       terminal" below for why this is a second manifest, not part
                                       of the one above)
work/                                 runtime writable dir (created on first run; git-ignored)
```

(`start.sh`/`run_podman.sh`/`shell_podman.sh`/`build_podman.sh` are the old
names from before the `container/{apptainer,podman}/` reorganization --
scripts below are invoked as `pixi run {build,marimo,shell}-{apptainer,podman}`,
or directly via their paths above.)

## Build

Building from source is **optional**. `pixi run marimo-apptainer` and
`pixi run marimo-podman` both default to pulling the pre-built image published
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
pixi run build-apptainer   # -> marimo_sandbox.sif
```

### Podman Build

**⚠️ Before your first Podman run ever: rootless Podman needs a
`/etc/subuid`/`/etc/subgid` range for your account, and that's not
something you can set up yourself — reach out to the HPC team first** if
you haven't run rootless Podman on this cluster before. Without it, Podman
can't create its user namespace at all, and you'll never get as far as the
storage setup this repo's scripts do automatically. This has to be
requested per-account, individually, by HPC -- it isn't granted by
default.

A range-enabled account isn't required for anything in this repo to work
-- everything described below (`ignore_chown_errors=true`,
`TAR_OPTIONS=--no-same-owner`, `podman unshare rm -rf` instead of a plain
`rm -rf`) is a fallback for the no-range case, expected to remain harmless
for an account that *has* a range too (not yet verified live either way
for that combination). This repo doesn't currently take advantage of a
range being present, e.g. to run containers as your real UID via
`--userns=keep-id` instead of root (see the "Identity" bullet below) --
that's a real possible follow-up now that a range can be requested, not
something implemented yet.

For Podman support:

```bash
pixi install
pixi run build-podman   # -> builds marimo_sandbox:latest
```

## Run the Marimo server

```bash
# Provide whichever API keys you need (forwarded automatically):
export ANTHROPIC_API_KEY=sk-...
export OPENAI_API_KEY=sk-...
export GEMINI_API_KEY=...          # or GOOGLE_API_KEY

pixi run marimo-apptainer             # serves http://<host>:8080 (Apptainer)
# or
pixi run marimo-podman                # serves http://<host>:8080 (Podman)
```

Open the printed URL (with the access token) in a browser. The notebook
`app/agents_demo.py` is copied into `./work` on first run.

### HTTPS (optional)

Marimo has no built-in TLS support, so `pixi run marimo-https` fronts the
same launch flow with a local [Caddy](https://caddyserver.com/) reverse
proxy:

```bash
pixi run marimo-https                 # serves https://<host>:8443 -> internal :8080
BACKEND=podman pixi run marimo-https  # force Podman, even if Apptainer is also on PATH
```

`container/https-wrap.sh` picks the same backend `pixi run marimo` would by
default (Apptainer if it's on `PATH`, else Podman) -- set `BACKEND=podman`
(or `BACKEND=apptainer`) to override that, e.g. to get Podman+HTTPS on a
host that also has Apptainer installed. `runnables.yaml`'s
`marimo-podman-https` runnable uses this to force Podman, since it's the
backend preferred by HPC admins (see "GPU passthrough" and "Podman storage
isolation" above) but the plain `marimo-https` runnable would otherwise
always prefer Apptainer when present.

`runnables.yaml` only exposes HTTPS runnables (`marimo-https`,
`marimo-podman-https`, and the web-terminal ones below) -- the plain-HTTP
`pixi run marimo-apptainer`/`marimo-podman` commands above still work
directly, just aren't offered as Fileglancer jobs, since an HTTP job would
carry Marimo's access token in the URL unencrypted.

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

### Web terminal (optional, alternative to Marimo)

`pixi run terminal-https` serves a web-based terminal instead of Marimo --
same sandbox (read-only host, writable `/work`, GPU passthrough), same
Caddy TLS-terminating setup as `marimo-https` above, just fronting
[ttyd](https://github.com/tsl0922/ttyd) (a conda-forge package, baked into
the image via `pixi.toml`) instead:

```bash
pixi run terminal-https                    # serves https://<host>:<port>
BACKEND=podman pixi run terminal-https     # force Podman
```

**Fileglancer app**: the web terminal's runnables live in their own
manifest, `terminal/runnables.yaml`, rather than the root `runnables.yaml`
-- Fileglancer discovers every `runnables.yaml` in a repo and offers each
as an independently addable app, so "Marimo AI Sandbox" and "Marimo AI
Sandbox - Web Terminal" show up as two separate app cards instead of one,
even though both live in this same repo. This means script paths in
`terminal/runnables.yaml`'s `command:` fields are one level up
(`../container/terminal-wrap.sh`, not `container/terminal-wrap.sh`) --
Fileglancer runs a job from the directory containing whichever manifest
it came from, not always the repo root, and `pixi run <path>` (unlike a
declared pixi *task* name) resolves a relative path against that same
directory, not the workspace root.

Useful for driving the agent CLIs (`claude`, `codex`, `gemini`, `agy`) or a
plain shell from a browser, with no separate SSH/terminal client needed --
e.g. from a Fileglancer job with no other terminal access. Under the hood,
`container/terminal-wrap.sh` runs `ttyd` *inside* the sandbox via
`shell.sh`'s command-override support (`./shell.sh -- ttyd ...`, added
alongside this feature) rather than a separate code path, so it gets the
exact same `--ro-paths`/`--work`/GPU handling an interactive `shell.sh`
session does. `shell.sh` now pulls the pre-built image from `ghcr.io`
first, same as `marimo.sh` always has, falling back to a local build only
if the pull fails -- it used to always build locally from scratch, so the
first-ever `terminal-https`/`shell-*` invocation on a given node paid a
multi-minute cold build. Confirmed live: this was the actual root cause of
a real Fileglancer `terminal-https` job showing a confusing `502` for
several minutes (Caddy only waits 30s for `ttyd` before starting anyway --
see the `--allow` `502` note below for the identical Caddy-vs-backend-
timing shape).

Auth is ttyd's own HTTP Basic Auth (`-c user:pass`), not a query-string
token like Marimo's -- the launch URL embeds the credential directly
(`https://terminal:<token>@host:port/`), which browsers use to
auto-authenticate the same way. The token is resolved the same way
Marimo's is (`$FG_SERVICE_TOKEN` if this is a Fileglancer job, else a
random token persisted at `$WORK/.terminal-token`), kept in its own file so
the two services don't share a credential even against the same `--work`.

**Not compatible with `--allow`/`$ALLOW_HOSTS`** (see "Sandbox strength"
below) -- same reason `marimo-https` isn't: the egress allowlist isolates
the container's network namespace, including its own loopback, so Caddy
(running outside the container, on the host) can no longer reach it.
`terminal-wrap.sh` hard-errors immediately if it's set, same as
`https-wrap.sh`. Use `pixi run shell-apptainer`/`shell-podman -- ttyd ...`
directly with `--allow` instead if you need both at once (no HTTPS
fronting in that case, so it isn't a Fileglancer-servable job).

### GPU passthrough (automatic)

`common.sh` detects a GPU at launch time (`nvidia-smi -L`) and passes it
through automatically — no flag needed, and no harm on a non-GPU node:

- **Apptainer:** adds `--nv`.
- **Podman:** adds `--device nvidia.com/gpu=all` (CDI-based, matching this
  host's `nvidia-container-toolkit` setup).

Verified end-to-end on an LSF `gpu_short` job: `apptainer exec --nv
marimo_sandbox.sif nvidia-smi` correctly sees the node's GPU.

**Podman's CDI path is now also verified end-to-end** (previously blocked in
testing by a stale `/etc/cdi/nvidia.yaml` on an earlier test node): on a real
`gpu_l4` LSF allocation, `pixi run shell-podman` correctly reported a real
GPU (`nvidia-smi -L` → `GPU 0: NVIDIA L4 (UUID: ...)`), including with two
concurrent Podman jobs from the same user on the same GPU node (see "Podman
storage isolation" below) and with the egress allowlist enabled at the same
time. If you hit a `crun: cannot stat ... libnvidia-nscq.so...` error
instead, that's the stale-CDI-spec issue: `/etc/cdi/nvidia.yaml` needs
regenerating (`nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`,
requires root) after a driver upgrade -- ask the HPC team, this repo can't
fix it from inside a container.

### Podman storage isolation (concurrent jobs on one GPU node)

`container/podman/lib.sh` gives every `marimo.sh`/`shell.sh` invocation its
own Podman `--root`/`--runroot`, keyed by `$LSB_JOBID` (or `$$-$RANDOM`
outside LSF), instead of a single storage location shared by every job from
that user. Without this, two concurrent Podman jobs landing on the same GPU
node can corrupt each other's storage -- confirmed independently by
[JaneliaScientificComputingSystems/agentic-sandbox](https://github.com/JaneliaScientificComputingSystems/agentic-sandbox)
(a related sandboxing project on this same cluster), whose Podman wrapper
this hardening is adapted from. The per-job store still shares the durable,
`/scratch`-backed image cache via `--storage-opt additionalimagestore`, so a
second concurrent job on the same node doesn't pay for a re-pull/re-build.
Also included: automatic storage staleness recovery after a node reboot
(`podman system migrate`/`reset`), and a watchdog for `catatonit` (Podman's
container-init) occasionally not getting reaped before being reparented to
PID 1, which otherwise can block `podman run` itself from ever returning.

Verified live: two concurrent `shell.sh` GPU sessions on the same `gpu_l4`
node both saw the GPU and returned their own distinct exit codes correctly,
with no storage corruption and no leftover per-job storage directories
afterward. One caveat found in testing, being transparent about it rather
than overclaiming: an orphaned `catatonit` occasionally still lingers past
job completion despite the watchdog (observed once in this testing, cleaned
up by `bkill`, which -- per the "Running under LSF" section below -- reaps
the entire job's process tree regardless of individual process reparenting).
This matches a known limitation agentic-sandbox's own investigation
documents as a low-frequency residual risk, not something this port
introduced.

Cleanup of a per-job storage directory uses `podman unshare rm -rf`, not a
plain `rm -rf` -- accounts on this cluster get no `/etc/subuid`/`/etc/subgid`
range unless one is explicitly requested from HPC (see the "Podman Build"
section's prerequisite note above), so without one, a plain `rm -rf` run as
your real user hits `Permission denied` on every file inside an overlay
diff layer -- confirmed live. This is a real difference from
agentic-sandbox's own cluster setup, which requires a subuid range as a
prerequisite for everyone; `podman unshare rm -rf` is expected to keep
working correctly for an account that *has* requested a range too (it
doesn't depend on there being no range), but that combination hasn't been
verified live yet -- only the no-range case has.

### Read-only model

`container/apptainer/marimo.sh` launches the container with `--contain` (host home and CWD are NOT
mounted; `/tmp` is a private tmpfs) and then:

- bind-mounts each path in `RO_PATHS` **read-only**;
- binds `./work` → `/work` **read-write** (override with `WORK=/path` or `--work /path`);
- sets `HOME=/work/home` (via `--home`, the only mechanism that works —
  apptainer refuses to set `HOME` via `--env`) and `TMPDIR=/work/tmp`, so
  Marimo notebooks live in `/work`; agent config dirs (`~/.claude`, ...) are
  **not** mounted by default at all — see
  [Sandbox strength](#sandbox-strength-what-this-does-and-doesnt-protect-against)
  below;
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
> pixi run marimo-apptainer --ro-paths "/groups/<lab> /nrs/<lab> ..."
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

### Sandbox strength: what this does and doesn't protect against

This is a **convenience** sandbox (protects the base image, scopes writable
storage to `/work`) rather than a **security** sandbox — it does not isolate
identity, network egress, or secrets. Concretely, what's in place and what
isn't:

- **Process visibility** — isolated. Apptainer runs with `--pid` (its own PID
  namespace; without it, `ps aux` inside would show the whole compute node's
  processes, not just this job's — verified). Podman isolates PIDs by
  default, no flag needed.
- **Resource limits** — partial. `container/entrypoint.sh` sets conservative
  rlimits (`ulimit -f`/`-u`) inside the container. Native cgroup-based limits
  (Apptainer's `--memory`/`--cpus`/`--pids-limit`, Podman's `--memory`) do
  **not** work reliably on Janelia's current HPC setup — Apptainer hard-fails
  without `systemd cgroups` enabled in `apptainer.conf`, and Podman silently
  accepts `--memory` without enforcing it under
  `--cgroup-manager=cgroupfs`. Both need infra changes outside this repo.
  The `resources:` block in `runnables.yaml` (cpus/memory/walltime) is the
  primary real control today, enforced by LSF at the job level.
- **Network egress** — **unrestricted by default**. Outbound internet access
  from inside the container is not blocked or allowlisted unless you opt in.
  `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` (and lowercase) are forwarded
  automatically if the launching shell already has them set, but there's no
  proxy or firewall provided by this repo by default — a compromised agent
  or a prompt-injected tool call could reach the open internet. Opt-in
  egress allowlist, **both backends**: pass `--allow HOST` (repeatable) or
  set `ALLOW_HOSTS="host1 host2"` to `marimo.sh`/`shell.sh`. When set, the
  container's network is fully isolated (Podman: `--network=none`;
  Apptainer: `--net --network none`, confirmed to give the same
  isolated-loopback-only result -- no bridge/NAT is configured on this
  host's unprivileged Apptainer install) and a host-side allowlist proxy
  (`container/allowlist_proxy.py`, reached via an in-container relay,
  `container/relay.py`) permits only the listed hostnames plus
  `conda.anaconda.org` (always included -- `entrypoint.sh`'s first-run `pixi
  install` needs conda-forge regardless of what a task itself needs
  allowed) — everything else gets an HTTP 403, logged to `proxy.log` inside
  the proxy's own private temp dir (printed at startup). **Covers HTTPS too,
  not just plain HTTP**: both `http_proxy` and `https_proxy` point at the
  same relay, and the proxy understands HTTP `CONNECT` (the standard way an
  HTTPS request reaches a proxy) -- it checks the `CONNECT` target hostname
  against the allowlist, then just relays the still-encrypted bytes without
  ever decrypting TLS. Confirmed live: `conda.anaconda.org` is fetched over
  HTTPS, and the `pixi install` verification above only succeeded through
  this proxy path. The real limit of this model: it's hostname-based (from
  the `CONNECT` line or the plain-HTTP `Host:` header), not deep packet
  inspection -- once a hostname is allowed, everything reachable *through*
  that encrypted connection (redirects, CDN backends, etc.) isn't separately
  checked. Adapted from
  [JaneliaScientificComputingSystems/agentic-sandbox](https://github.com/JaneliaScientificComputingSystems/agentic-sandbox),
  which uses the identical mechanism (and the identical trust boundary) for
  its bwrap sandbox. **Not compatible with the HTTPS runnables**
  (`marimo-https`/`marimo-podman-https`): the allowlist isolates the
  container's network namespace, including its own loopback, so Caddy --
  which runs *outside* the container, on the host -- can no longer reach the
  service it's supposed to front. Confirmed live: this used to fail silently
  with a plain Caddy 502, no explanation; `https-wrap.sh` now hard-errors
  immediately instead if `--allow`/`$ALLOW_HOSTS` is set. Use the plain-HTTP
  `marimo-apptainer`/`marimo-podman` tasks (or `shell-apptainer`/
  `shell-podman`) with `--allow` instead.
- **Identity** — **not isolated**. The container runs as your real
  uid/gid with all your real HHMI/Janelia group memberships, not a scoped
  service account. This is inherent to how Fileglancer/LSF jobs execute
  today, not something a container launch script controls.
- **Agent config dirs** (`~/.claude`, `~/.gemini`, `~/.codex`) are **not**
  mounted by default at all — a fresh sandbox starts with no host
  credentials/settings for any of them. Opt in per tool with
  `CLAUDE_CONFIG`/`GEMINI_CONFIG`/`CODEX_CONFIG`, each set to `rw` (writable
  — needed for things like a `setup-token` credential file, conversation
  history, or session resume) or `ro` (read-only — e.g. if you're using an
  API key instead of a subscription login, and want to remove
  settings/hooks self-tampering as a persistence vector). Whether to seed
  `/work/home/.claude` (etc.) by copying your real config there first,
  instead of a live bind, is up to you — this repo doesn't do that
  automatically.
- **`/work` is a regular NFS bind, not `noexec`.** The user-editable pixi
  environment (`container/app/pyproject.toml`, seeded by `entrypoint.sh`)
  installs Python/marimo/every console script *into* `/work/.pixi` and execs
  them from there — a `noexec` mount would break marimo itself. Properly
  separating an exec-allowed subtree (the pixi env) from a `noexec` one
  (notebooks/data) would be a real architecture change, not a flag.
- **`bsub` (LSF job submission) is off by default.** A container launched
  without `--enable-bsub`/`ENABLE_BSUB=1` has no LSF client at all inside
  it — an agent calling `bsub` gets a clear error, not a silent failure.
  Turning this on hands the sandbox the ability to submit new cluster jobs
  under your own identity, on top of the one it's already running in — see
  [Submitting LSF jobs from inside the sandbox](#submitting-lsf-jobs-from-inside-the-sandbox-bsub-wrapper).

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
shell started via `pixi run shell-apptainer`/`pixi run shell-podman` after `cd /work`). Its `reference/finding-marimo.md`
has been locally modified to point directly at this sandbox's pixi-managed
Python environment (`/work/pyproject.toml`) instead of the generic
uv/global/sandbox decision tree.

`entrypoint.sh` also seeds `AGENTS.md` into `./work` (with `CLAUDE.md`/
`GEMINI.md` symlinked to it, so Claude Code/Codex/Gemini CLI all read the
same content) — a short note telling an agent CLI to fetch
[hpc.int.janelia.org/docs/ai-agent-hints](https://hpc.int.janelia.org/docs/ai-agent-hints)
before touching the Janelia cluster (LSF, storage tiers, GPU queues,
common agent mistakes), since that page is kept current while any
pasted/cached copy goes stale.

## Interactive / terminal use

```bash
pixi run shell-apptainer   # Apptainer
# or
pixi run shell-podman      # Podman

# then, inside the container:
claude -p "summarize this project"
codex exec "..."
gemini -p "..."
agy -p "..."
```

## Submitting LSF jobs from inside the sandbox (bsub wrapper)

LSF has no notion of "run my job inside a container" — a bare `bsub -n 4
python train.py` runs `train.py` directly on whatever node LSF picks, outside
the sandbox entirely. This repo ships an **opt-in** `bsub` wrapper
(`container/bsub-wrapper/bin/bsub`, always on `PATH` inside the image) that
lets a wrapped job re-enter the *same* sandbox image on that other node
instead.

**Off by default.** Without `--enable-bsub` (or `ENABLE_BSUB=1`), the real
LSF client isn't even bind-mounted in, so calling `bsub` inside the container
fails immediately with an explanatory error — enabling this is a deliberate
expansion of what the sandbox can do (it can now submit new cluster jobs
under your identity, on top of the one it's already running in), not
something that happens implicitly.

```bash
pixi run marimo-apptainer --enable-bsub --ro-paths "/groups/scicompsoft /nrs/scicompsoft"
```

**Apptainer only, for now.** Verified end-to-end: a wrapped job submitted
from inside a live Apptainer sandbox landed on a different real node and
correctly re-entered the same sandbox image there. The Podman backend hits
a real, unresolved blocker: LSF's `eauth` (external authentication) uses
Kerberos via `sssd-kcm`, and fails inside a rootless Podman container
(`Failed in an LSF library call: External authentication failed`) even
after fixing UID mapping (`--userns=keep-id`), bind-mounting the SSSD/KCM
sockets, and granting all capabilities/unconfined seccomp — this is a
deeper incompatibility between rootless Podman's isolation and this
cluster's Kerberos-based LSF auth, not a bug in the wrapper itself.
`--enable-bsub` therefore **refuses to start on the Podman backend** (a
hard error, not just a warning) until this is root-caused -- likely needs
Janelia IT input on what `eauth`/Kerberos actually requires inside a
container's network/mount namespace.

`$WORK` must be on shared storage (`/groups` or `/nrs`, not `/scratch`, which
is local to a single node) — the wrapper writes a small re-entry script
there that the job needs to see from whatever node it lands on.

Inside the container, wrap a job's command with a literal `--`:

```bash
bsub -n 4 -W 1:00 -o out.log -- python train.py --epochs 5
```

Everything before `--` is passed straight through to the real `bsub` as LSF
options; everything after becomes the job's command, re-entered inside this
same sandbox image (same binds, same env) wherever LSF schedules it. A
`bsub` call with **no** `--` (e.g. `bsub -Is /bin/bash`, or a script piped on
stdin) is passed through completely unwrapped — it runs bare-metal on the
target node, exactly as it would with no wrapper present.

## Credentials

Credentials are **never baked into the image**. Any host env var matching
`ANTHROPIC_*`, `OPENAI_*`, `GEMINI_*`, `GOOGLE_*`, `*_API_KEY`, or `*_AUTH_TOKEN`
is forwarded into the container by `start.sh` / `shell.sh`.

If you'd rather use a subscription login (e.g. `claude setup-token`) than an
API key, its credential file lives under `~/.claude`, which isn't mounted by
default — set `CLAUDE_CONFIG=rw` (or `GEMINI_CONFIG`/`CODEX_CONFIG=rw` for
the other CLIs) to bind it in. See
[Sandbox strength](#sandbox-strength-what-this-does-and-doesnt-protect-against)
for the `rw`/`ro` distinction.

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
- **Tool versions**: conda packages in `pixi.toml`/`container/app/pyproject.toml`
  are pinned to a version range (e.g. `>=26.6.0,<26.7`) and locked via
  `pixi.lock`; npm agent CLIs are unpinned, so rebuilding always picks up
  their latest release. Bump the conda ranges and re-run `pixi update` for
  newer versions; there's no equivalent lock for the npm packages.
- **Marimo auth:** `marimo edit` prints a per-session access token; use it (or
  `--token-password`) when exposing the port beyond localhost.
- **HTTPS:** plain `marimo`/`start.sh` serve HTTP only. Use `pixi run
  marimo-https` for a locally TLS-terminated option (see above); its
  self-signed cert requires installing the printed CA cert to avoid browser
  warnings.
