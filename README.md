# comfyui-local

Personal backup repo for my ComfyUI setup: workflows, workspace settings, custom node lists, prompts, and other config I don't want to lose or rebuild by hand.

This repo stores the **files that define the setup**, not the heavy stuff. Models, checkpoints, LoRAs, and generated outputs stay out of git (see [What not to commit](#what-not-to-commit)).

## Layout

```
comfyui-local/
├── workflows/        # Workflow JSON files (exported or from user/default/workflows)
├── workspace/        # ComfyUI user settings (comfy.settings.json, templates, keybindings)
├── custom-nodes/     # List of installed custom nodes + versions (not the node code itself)
├── models/           # Model manifests only: names, sources, hashes, download links
├── prompts/          # Reusable prompts, negative prompts, style notes
├── inputs/           # Small reference images used by workflows (keep it light)
├── scripts/          # Helper scripts (backup, restore, setup)
└── notes/            # Setup notes, troubleshooting, things learned
```

Create folders as they're needed; not all of them have to exist yet.

## What to back up

| What | Where it lives in ComfyUI | Goes in |
|---|---|---|
| Saved workflows | `ComfyUI/user/default/workflows/` | `workflows/` |
| UI settings | `ComfyUI/user/default/comfy.settings.json` | `workspace/` |
| Node templates | `ComfyUI/user/default/comfy.templates.json` | `workspace/` |
| Extra model paths | `ComfyUI/extra_model_paths.yaml` | `workspace/` |
| Custom node list | `ComfyUI/custom_nodes/` (folder names + git remotes) | `custom-nodes/` |
| Python deps | `pip freeze` from the ComfyUI env | `custom-nodes/requirements.lock.txt` |

For ComfyUI Desktop on macOS, the user folder is usually under `~/Documents/ComfyUI/user/` (check **Settings → About** for the actual path).

### Snapshot custom nodes

Record which node packs are installed and at what commit, so they can be reinstalled later:

```bash
cd /path/to/ComfyUI/custom_nodes
for d in */; do
  if [ -d "$d/.git" ]; then
    echo "${d%/} $(git -C "$d" remote get-url origin) $(git -C "$d" rev-parse HEAD)"
  fi
done > ~/Desktop/repo/comyui-local/custom-nodes/nodes.txt
```

If ComfyUI-Manager is installed, its snapshot feature (**Manager → Snapshot Manager → Save snapshot**) also works; copy the JSON from `ComfyUI/user/default/ComfyUI-Manager/snapshots/` into `custom-nodes/`.

## What not to commit

- Model weights (`.safetensors`, `.ckpt`, `.pt`, `.pth`, `.bin`, `.gguf`, `.onnx`)
- Generated outputs (`ComfyUI/output/`) and temp files (`ComfyUI/temp/`)
- The `custom_nodes/` code itself (record the list instead)
- Python virtual environments
- API keys and tokens (e.g. in `comfy.settings.json` or `.env` files). Check settings files before committing.

For models, keep a manifest in `models/` instead, e.g.:

```
# models/checkpoints.md
- sd_xl_base_1.0.safetensors — https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0
- flux1-dev-fp8.safetensors — <source link>
```

## Restoring on a new machine

1. Install ComfyUI (Desktop app or `git clone https://github.com/comfyanonymous/ComfyUI`).
2. Copy `workspace/` files back into `ComfyUI/user/default/`.
3. Copy `workflows/` into `ComfyUI/user/default/workflows/`.
4. Reinstall custom nodes from `custom-nodes/nodes.txt` (or restore the Manager snapshot).
5. Download models listed in `models/` into the matching `ComfyUI/models/` subfolders.
6. Start ComfyUI and open a workflow to check for missing nodes or models.

## Conventions

- Name workflows descriptively: `sdxl-portrait-upscale.json`, not `workflow (3).json`.
- One commit per meaningful change, with a message that says what changed (e.g. `add flux inpaint workflow`).
- Put anything non-obvious about a workflow (required models, settings, quirks) in `notes/` or a short comment next to it.
