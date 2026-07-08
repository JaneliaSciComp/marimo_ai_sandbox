import marimo

__generated_with = "0.23.8"
app = marimo.App(width="medium")


@app.cell
def _():
    import marimo as mo
    import os
    import shutil
    import subprocess
    return mo, os, shutil, subprocess


@app.cell
def _(mo):
    mo.md(
        """
        # Marimo AI Sandbox — agent demo

        This notebook runs inside a **read-only** Apptainer container. The host
        filesystem is mounted read-only; the only writable location is `/work`
        (this directory). The bundled AI coding agent CLIs are on `PATH`:

        - `claude` — Claude Code
        - `codex` — OpenAI Codex
        - `gemini` — Gemini CLI (native ACP via `--acp`)
        - `agy` — Antigravity CLI

        Below we detect which agents are installed and which credentials are
        present, then run a one-shot prompt against a chosen agent.
        """
    )
    return


@app.cell
def _(mo, os, shutil):
    _agents = {
        "claude": ("Claude Code", "ANTHROPIC_API_KEY"),
        "codex": ("OpenAI Codex", "OPENAI_API_KEY"),
        "gemini": ("Gemini CLI", "GEMINI_API_KEY / GOOGLE_API_KEY"),
        "agy": ("Antigravity", "GEMINI_API_KEY / GOOGLE_API_KEY"),
    }
    _rows = []
    for _bin, (_name, _key) in _agents.items():
        _path = shutil.which(_bin)
        _has_key = any(os.environ.get(k.strip()) for k in _key.replace("/", " ").split())
        _rows.append(
            f"| `{_bin}` | {_name} | {'✅' if _path else '❌'} | "
            f"{'✅' if _has_key else '⚠️ missing'} ({_key}) |"
        )
    mo.md(
        "### Installed agents & credentials\n\n"
        "| CLI | Agent | On PATH | API key |\n"
        "|-----|-------|---------|---------|\n" + "\n".join(_rows)
    )
    return


@app.cell
def _(mo, shutil):
    _available = [b for b in ("claude", "codex", "gemini", "agy") if shutil.which(b)]
    agent = mo.ui.dropdown(
        options=_available or ["(none installed)"],
        value=(_available[0] if _available else "(none installed)"),
        label="Agent",
    )
    prompt = mo.ui.text_area(
        value="List the files in the current directory and summarize what this project does.",
        label="Prompt",
        full_width=True,
    )
    run_button = mo.ui.run_button(label="Run agent")
    mo.vstack([agent, prompt, run_button])
    return agent, prompt, run_button


@app.cell
def _(agent, mo, prompt, run_button, subprocess):
    mo.stop(not run_button.value, mo.md("*Press **Run agent** to execute.*"))

    # One-shot / headless invocation flags per agent.
    _cmds = {
        "claude": ["claude", "-p", prompt.value],
        "codex": ["codex", "exec", prompt.value],
        "gemini": ["gemini", "-p", prompt.value],
        "agy": ["agy", "-p", prompt.value],
    }
    _cmd = _cmds.get(agent.value)
    mo.stop(_cmd is None, mo.md("⚠️ No agent selected / installed."))

    try:
        _proc = subprocess.run(
            _cmd,
            capture_output=True,
            text=True,
            timeout=300,
            cwd="/work",
        )
        _out = _proc.stdout or ""
        _err = _proc.stderr or ""
        _result = mo.vstack(
            [
                mo.md(f"**exit code:** `{_proc.returncode}`"),
                mo.md("**stdout**"),
                mo.plain_text(_out[-20000:]),
                mo.md("**stderr**") if _err.strip() else mo.md(""),
                mo.plain_text(_err[-8000:]) if _err.strip() else mo.md(""),
            ]
        )
    except Exception as e:  # noqa: BLE001
        _result = mo.md(f"❌ Failed to run `{' '.join(_cmd)}`:\n\n```\n{e}\n```")

    _result
    return


@app.cell
def _(mo):
    mo.md(
        """
        ---
        **Note:** writes only succeed under `/work`. Try writing elsewhere to
        confirm the read-only sandbox — e.g. asking an agent to modify a file in
        a read-only mount will fail, which is by design.
        """
    )
    return


if __name__ == "__main__":
    app.run()
