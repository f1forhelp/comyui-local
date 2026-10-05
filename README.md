# comfyui-local

Personal backup repo for my ComfyUI setup: workflows, workspace settings, custom node lists, prompts, and other config I don't want to lose or rebuild by hand.

This repo stores the **files that define the setup**, not the heavy stuff. Models, checkpoints, LoRAs, and generated outputs stay out of git (see [What not to commit](#what-not-to-commit)).

## Current setup

ComfyUI is managed with [comfy-cli](https://github.com/Comfy-Org/comfy-cli):

| | Path |
|---|---|
| ComfyUI workspace | `~/comfy` |
| Python venv (3.12) with comfy-cli | `~/comfy-env` |
| `comfy` command | `~/.local/bin/comfy` → `~/comfy-env/bin/comfy` |
| UI | http://127.0.0.1:8188 |

(Comfy Desktop is also installed at `/Applications/Comfy Desktop.app` with data in `~/ComfyUI-Installs/ComfyUI`, but it's a separate install. This repo backs up the CLI workspace.)

## Launching ComfyUI

```bash
comfy launch                 # run in this terminal; Ctrl+C to stop
comfy launch --background    # run in the background
comfy stop                   # stop the background server
```

Then open the UI:

```bash
open http://127.0.0.1:8188
```

Useful checks:

```bash
comfy which                  # show which workspace the CLI is using
comfy logs                   # show server logs
lsof -iTCP:8188 -sTCP:LISTEN # is something already running on 8188?
```

If ComfyUI is already running, launching again will clash on port 8188. Open the URL instead, or run `comfy stop --port 8188` first.

## Layout

```
comfyui-local/
├── workflows/                    # Saved workflows (mirror of user/default/workflows)
├── workspace/
│   ├── user-default/             # Rest of user/default: settings, templates, keybindings, ...
│   └── extra_model_paths.yaml    # If you use one
├── custom-nodes/
│   ├── snapshot.json             # Restorable snapshot: node packs + pip packages
│   └── nodes.txt                 # Plain list: name, git remote, commit
├── models/
│   └── installed.txt             # Model files present locally (auto-generated)
├── backup-meta/
│   └── layout.txt                # ComfyUI folder layout at last backup (auto-generated)
├── scripts/
│   └── backup.sh                 # Backup script (see below)
├── prompts/                      # Reusable prompts, negative prompts, style notes
├── inputs/                       # Small reference images used by workflows (keep it light)
└── notes/                        # Setup notes, troubleshooting, things learned
```

Everything above `scripts/` is written by the backup script. `prompts/`, `inputs/` and `notes/` are for things you add by hand; create them when needed.

## Backing up

ComfyUI does **not** save into this repo by itself. Run the backup script to copy everything across and commit it:

```bash
./scripts/backup.sh
```

It copies:

| What | From ComfyUI | To |
|---|---|---|
| Workflows | `user/default/workflows/` | `workflows/` |
| Settings, templates, keybindings | `user/default/` (everything else) | `workspace/user-default/` |
| Extra model paths | `extra_model_paths.yaml` | `workspace/` |
| Custom nodes + pip packages | `comfy node save-snapshot` | `custom-nodes/snapshot.json` |
| Custom node list | `custom_nodes/` (name, git remote, commit) | `custom-nodes/nodes.txt` |
| Model file list | `models/` (names and sizes only) | `models/installed.txt` |

Then it commits (`backup: <date> (ComfyUI <version>)`) and pushes if the branch has an upstream. If nothing changed, it does nothing.

Options:

```bash
./scripts/backup.sh --dry-run            # show what would change, write nothing
./scripts/backup.sh --no-commit          # copy files but don't commit
./scripts/backup.sh --no-push            # commit but don't push
./scripts/backup.sh --comfy-dir ~/comfy  # use this ComfyUI folder
./scripts/backup.sh --reset-path         # forget a previously entered path
./scripts/backup.sh --force              # continue past layout/safety checks
```

**Finding ComfyUI.** The script looks, in order, at: `--comfy-dir` / `$COMFY_DIR`, a path saved in `.comfy-path` from an earlier run, a running ComfyUI process (including any `--user-directory` / `--base-directory` it was started with), comfy-cli's default workspace (`comfy which`), then common locations (`~/comfy`, `~/ComfyUI`, `~/Documents/ComfyUI`, ...). If none match, it asks for the path and saves it to `.comfy-path` (git-ignored, since it's machine-specific).

**Layout check.** Before copying, the script reads ComfyUI's own code (`folder_paths.py`, `app/user_manager.py`) to see where the user, workflows and models folders are, and compares that with `backup-meta/layout.txt` from the last backup. If an update moved or renamed any of them, it stops without touching the repo. Version bumps and new files in `user/default` are only reported.

**Safety checks.**
- If ComfyUI has 0 workflows but the repo has some, it refuses to mirror (which would delete them from the repo).
- Before committing, it scans for things that look like API keys or tokens (Hugging Face, OpenAI-style, GitHub, Comfy API keys, `"...api_key": "..."`). If it finds any, it stops and lists the file and line.

## What not to commit

- Model weights (`.safetensors`, `.ckpt`, `.pt`, `.pth`, `.bin`, `.gguf`, `.onnx`)
- Generated outputs (`ComfyUI/output/`) and temp files (`ComfyUI/temp/`)
- The `custom_nodes/` code itself (record the list instead)
- Python virtual environments
- API keys and tokens (e.g. in `comfy.settings.json` or `.env` files). The backup script scans for these, but check anyway.

`.gitignore` already blocks model weights, outputs, temp files, Python caches, `.env` files, logs and local databases.

`models/installed.txt` lists which model files you have. Add where to download them in another file in `models/`, e.g.:

```
# models/checkpoints.md
- sd_xl_base_1.0.safetensors — https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0
- flux1-dev-fp8.safetensors — <source link>
```

## Restoring on a new machine

What you need: this repo, Python 3.12, and an internet connection for models. Everything else is rebuilt from the repo.

1. Clone this repo:
   ```bash
   git clone <this-repo-url> ~/Desktop/repo/comyui-local
   ```
2. Create the venv and install comfy-cli:
   ```bash
   python3.12 -m venv ~/comfy-env
   ~/comfy-env/bin/pip install comfy-cli
   mkdir -p ~/.local/bin && ln -sf ~/comfy-env/bin/comfy ~/.local/bin/comfy
   ```
   (Make sure `~/.local/bin` is on your `PATH`.)
3. Install ComfyUI + ComfyUI-Manager into `~/comfy` (`--m-series` for Apple Silicon Macs):
   ```bash
   comfy --workspace ~/comfy install --m-series
   comfy set-default ~/comfy
   ```
4. Restore settings and workflows:
   ```bash
   mkdir -p ~/comfy/user/default/workflows
   cp -R workspace/user-default/. ~/comfy/user/default/
   cp -R workflows/. ~/comfy/user/default/workflows/
   [ -f workspace/extra_model_paths.yaml ] && cp workspace/extra_model_paths.yaml ~/comfy/
   ```
5. Restore custom nodes:
   ```bash
   comfy node restore-snapshot custom-nodes/snapshot.json
   ```
6. Download the models listed in `models/installed.txt` into the matching `~/comfy/models/` subfolders (`comfy model download --url <link> --relative-path models/<folder>` works for direct links).
7. Re-enter API keys / tokens (Hugging Face, API nodes, etc.). These are not in the repo.
8. Launch (see [Launching ComfyUI](#launching-comfyui)) and open a workflow to check for missing nodes or models.

## Conventions

- Name workflows descriptively: `sdxl-portrait-upscale.json`, not `workflow (3).json`.
- Run `./scripts/backup.sh` after a session where you saved workflows or installed nodes. For hand-made changes (notes, prompts), commit with a message that says what changed (e.g. `add flux inpaint notes`).
- Put anything non-obvious about a workflow (required models, settings, quirks) in `notes/` or a short comment next to it.
