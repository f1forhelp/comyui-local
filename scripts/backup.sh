#!/usr/bin/env bash
#
# Back up a local ComfyUI install into this repo, then commit (and push if
# the branch has an upstream).
#
# What gets copied:
#   user/default/workflows/      -> workflows/
#   user/default/ (the rest)     -> workspace/user-default/
#   extra_model_paths.yaml       -> workspace/extra_model_paths.yaml
#   custom node snapshot         -> custom-nodes/snapshot.json, custom-nodes/nodes.txt
#   list of installed models     -> models/installed.txt
#   ComfyUI layout fingerprint   -> backup-meta/layout.txt
#
# Finding ComfyUI (first match wins):
#   1. --comfy-dir PATH or $COMFY_DIR
#   2. path saved in .comfy-path from an earlier run
#   3. a running ComfyUI process
#   4. comfy-cli's default workspace (`comfy which`)
#   5. common install locations
#   6. ask (interactive terminals only), then save the answer to .comfy-path
#
# Before copying anything, the script checks that ComfyUI's folder layout is
# what it expects and compares it with the layout recorded by the last backup.
# If an update moved the user/workflows folders, it stops instead of backing
# up the wrong place (override with --force).
#
# Usage: scripts/backup.sh [--comfy-dir PATH] [--dry-run] [--no-commit]
#                          [--no-push] [--force] [--reset-path]
#
# Works with the stock macOS bash (3.2).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATH_FILE="$REPO_DIR/.comfy-path"
# lsof lives in /usr/sbin on macOS, which cron/launchd PATHs often leave out.
LSOF="$(command -v lsof 2>/dev/null || echo /usr/sbin/lsof)"
LAYOUT_FILE="$REPO_DIR/backup-meta/layout.txt"

COMFY_DIR_ARG="${COMFY_DIR:-}"
DRY_RUN=0
DO_COMMIT=1
DO_PUSH=1
FORCE=0

# Overridden when ComfyUI is running with --user-directory / --base-directory.
USER_DIR_OVERRIDE=""
BASE_DIR_OVERRIDE=""

if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_YEL=""; C_GRN=""; C_DIM=""; C_OFF=""
fi

info() { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s! %s%s\n' "$C_YEL" "$*" "$C_OFF" >&2; }
die()  { printf '%s✗ %s%s\n' "$C_RED" "$*" "$C_OFF" >&2; exit 1; }

usage() {
  sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --comfy-dir)  [ $# -ge 2 ] || die "--comfy-dir needs a path"; COMFY_DIR_ARG="$2"; shift 2 ;;
    --comfy-dir=*) COMFY_DIR_ARG="${1#*=}"; shift ;;
    --dry-run)    DRY_RUN=1; DO_COMMIT=0; DO_PUSH=0; shift ;;
    --no-commit)  DO_COMMIT=0; DO_PUSH=0; shift ;;
    --no-push)    DO_PUSH=0; shift ;;
    --force)      FORCE=1; shift ;;
    --reset-path) rm -f "$PATH_FILE"; shift ;;
    -h|--help)    usage ;;
    *)            die "Unknown option: $1 (see --help)" ;;
  esac
done

expand_path() {
  local p="$1"
  case "$p" in
    "~")   p="$HOME" ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
  esac
  # Strip a trailing slash, but keep "/" itself.
  [ "$p" != "/" ] && p="${p%/}"
  printf '%s' "$p"
}

# A ComfyUI install has main.py and folder_paths.py at its root.
is_comfy_dir() {
  [ -n "$1" ] && [ -f "$1/main.py" ] && [ -f "$1/folder_paths.py" ]
}

# Finds a running ComfyUI (via its working directory) and records any
# --user-directory / --base-directory it was started with. Sets RUNNING_DIR,
# USER_DIR_OVERRIDE and BASE_DIR_OVERRIDE; call it directly, not in $(...).
detect_running() {
  local pid cmd cwd prev arg
  while read -r pid cmd; do
    case "$cmd" in *main.py*) ;; *) continue ;; esac
    cwd="$("$LSOF" -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1 || true)"
    is_comfy_dir "$cwd" || continue
    RUNNING_DIR="$cwd"
    prev=""
    for arg in $cmd; do
      case "$prev" in
        --user-directory) USER_DIR_OVERRIDE="$arg" ;;
        --base-directory) BASE_DIR_OVERRIDE="$arg" ;;
      esac
      case "$arg" in
        --user-directory=*) USER_DIR_OVERRIDE="${arg#*=}" ;;
        --base-directory=*) BASE_DIR_OVERRIDE="${arg#*=}" ;;
      esac
      prev="$arg"
    done
    return 0
  done < <(ps -axo pid=,command= 2>/dev/null || true)
  return 0
}

detect_comfy_cli() {
  command -v comfy >/dev/null 2>&1 || return 1
  comfy --json which 2>/dev/null \
    | sed -n 's/.*"workspace_path": *"\([^"]*\)".*/\1/p' | head -1
}

prompt_for_dir() {
  [ -t 0 ] || die "Couldn't find ComfyUI. Pass --comfy-dir PATH or set COMFY_DIR."
  warn "Couldn't find a ComfyUI install automatically."
  local answer
  while true; do
    read -r -e -p "Path to your ComfyUI folder (the one with main.py): " answer
    answer="$(expand_path "$answer")"
    if is_comfy_dir "$answer"; then
      printf '%s' "$answer"
      return 0
    fi
    warn "'$answer' doesn't look like ComfyUI (no main.py / folder_paths.py). Try again, or Ctrl+C to quit."
  done
}

find_comfy_dir() {
  local candidate source

  if [ -n "$COMFY_DIR_ARG" ]; then
    candidate="$(expand_path "$COMFY_DIR_ARG")"
    is_comfy_dir "$candidate" || die "'$candidate' doesn't look like ComfyUI (no main.py / folder_paths.py)."
    FOUND_DIR="$candidate"; FOUND_SOURCE="--comfy-dir / COMFY_DIR"; return
  fi

  if [ -f "$PATH_FILE" ]; then
    candidate="$(expand_path "$(head -1 "$PATH_FILE")")"
    if is_comfy_dir "$candidate"; then
      FOUND_DIR="$candidate"; FOUND_SOURCE="saved path (.comfy-path)"; return
    fi
    warn "Saved path '$candidate' is no longer a ComfyUI install, looking again."
  fi

  candidate="$RUNNING_DIR"
  if is_comfy_dir "$candidate"; then
    FOUND_DIR="$candidate"; FOUND_SOURCE="running ComfyUI process"; return
  fi

  candidate="$(detect_comfy_cli || true)"
  if is_comfy_dir "$candidate"; then
    FOUND_DIR="$candidate"; FOUND_SOURCE="comfy-cli default workspace"; return
  fi

  for candidate in "$HOME/comfy" "$HOME/ComfyUI" "$HOME/Documents/ComfyUI" \
                   "$HOME/Desktop/ComfyUI" "$HOME/ComfyUI-Installs/ComfyUI/ComfyUI"; do
    if is_comfy_dir "$candidate"; then
      FOUND_DIR="$candidate"; FOUND_SOURCE="common location"; return
    fi
  done

  FOUND_DIR="$(prompt_for_dir)"; FOUND_SOURCE="entered by you"
  if [ "$DRY_RUN" -eq 0 ]; then
    printf '%s\n' "$FOUND_DIR" > "$PATH_FILE"
    info "${C_DIM}Saved to .comfy-path for next time (--reset-path to forget it).${C_OFF}"
  fi
}

# ---------------------------------------------------------------------------
# Layout check
# ---------------------------------------------------------------------------

# Reads the folder names ComfyUI's own code uses, so a renamed folder in an
# update shows up here even before any files move.
read_layout() {
  local fp="$COMFY/folder_paths.py" um="$COMFY/app/user_manager.py"

  L_VERSION="$(sed -n 's/^__version__ *= *"\(.*\)".*/\1/p' "$COMFY/comfyui_version.py" 2>/dev/null | head -1)"
  L_USER_SUBDIR="$(sed -n 's/^user_directory *= *os\.path\.join(base_path, *"\([^"]*\)").*/\1/p' "$fp" | head -1)"
  L_MODELS_SUBDIR="$(sed -n 's/^ *models_dir *= *os\.path\.join(base_path, *"\([^"]*\)").*/\1/p' "$fp" | head -1)"
  L_DEFAULT_USER="$(sed -n 's/^default_user *= *"\([^"]*\)".*/\1/p' "$um" 2>/dev/null | head -1)"

  : "${L_VERSION:=unknown}"
  : "${L_USER_SUBDIR:=unknown}"
  : "${L_MODELS_SUBDIR:=unknown}"
  : "${L_DEFAULT_USER:=unknown}"
}

write_layout() {
  local entries
  entries="$(cd "$USER_DEFAULT" 2>/dev/null && ls -1A 2>/dev/null | grep -v '^\.DS_Store$' | paste -sd, - || true)"
  cat <<EOF
# Written by scripts/backup.sh. Compared on every run to catch layout changes
# from ComfyUI updates. Don't edit by hand.
comfyui_version=$L_VERSION
user_subdir=$L_USER_SUBDIR
default_user=$L_DEFAULT_USER
models_subdir=$L_MODELS_SUBDIR
workflows_dir=$( [ -d "$WORKFLOWS_SRC" ] && echo present || echo missing )
custom_nodes_dir=$( [ -d "$COMFY/custom_nodes" ] && echo present || echo missing )
user_default_entries=$entries
EOF
}

layout_value() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -1; }

check_layout() {
  local problems=0 key old new

  # Hard checks: the code no longer says where things are, or the folders are gone.
  if [ -z "$USER_DIR_OVERRIDE" ] && [ -z "$BASE_DIR_OVERRIDE" ] && [ "$L_USER_SUBDIR" = "unknown" ]; then
    warn "Can't find where folder_paths.py defines the user directory. ComfyUI may have changed its layout."
    problems=1
  fi
  if [ "$L_DEFAULT_USER" = "unknown" ]; then
    warn "Can't find the default user name in app/user_manager.py. ComfyUI may have changed its layout."
    problems=1
  fi
  if [ ! -d "$USER_DEFAULT" ]; then
    warn "User folder not found: $USER_DEFAULT"
    problems=1
  fi
  [ -d "$COMFY/custom_nodes" ] || warn "custom_nodes/ not found in $COMFY"

  # Compare with the layout recorded by the last backup.
  if [ -f "$LAYOUT_FILE" ]; then
    for key in user_subdir default_user models_subdir workflows_dir custom_nodes_dir; do
      old="$(layout_value "$key" "$LAYOUT_FILE")"
      new="$(layout_value "$key" "$NEW_LAYOUT")"
      if [ -n "$old" ] && [ "$old" != "$new" ]; then
        warn "Layout changed since last backup: $key was '$old', now '$new'."
        problems=1
      fi
    done

    old="$(layout_value comfyui_version "$LAYOUT_FILE")"
    [ "$old" != "$L_VERSION" ] && info "ComfyUI version changed: ${old:-?} -> $L_VERSION"

    old="$(layout_value user_default_entries "$LAYOUT_FILE")"
    new="$(layout_value user_default_entries "$NEW_LAYOUT")"
    if [ "$old" != "$new" ]; then
      info "Contents of user/default changed:"
      info "${C_DIM}  before: ${old:-<empty>}${C_OFF}"
      info "${C_DIM}  now:    ${new:-<empty>}${C_OFF}"
    fi
  fi

  if [ "$problems" -ne 0 ]; then
    if [ "$FORCE" -eq 1 ]; then
      warn "Continuing anyway because of --force."
    else
      die "Stopping before touching the repo. Check the layout, then re-run with --force if it's correct."
    fi
  else
    ok "Layout check passed (ComfyUI $L_VERSION)"
  fi
}

# ---------------------------------------------------------------------------
# Copying
# ---------------------------------------------------------------------------

count_json() { { find "$1" -type f -name '*.json' 2>/dev/null || true; } | wc -l | tr -d ' '; }

sync_dir() { # src dest [rsync args...]
  local src="$1" dest="$2"; shift 2
  local flags="-a --delete --exclude=.DS_Store"
  [ "$DRY_RUN" -eq 1 ] && flags="$flags -n -v"
  [ "$DRY_RUN" -eq 1 ] || mkdir -p "$dest"
  # shellcheck disable=SC2086
  rsync $flags "$@" "$src/" "$dest/"
}

backup_workflows() {
  local dest="$REPO_DIR/workflows" src_n dest_n
  if [ ! -d "$WORKFLOWS_SRC" ]; then
    warn "No workflows folder yet ($WORKFLOWS_SRC). Skipping workflows."
    return
  fi
  src_n="$(count_json "$WORKFLOWS_SRC")"
  dest_n="$(count_json "$dest")"
  # Mirroring an empty folder would delete every backed-up workflow.
  if [ "$src_n" -eq 0 ] && [ "$dest_n" -gt 0 ] && [ "$FORCE" -eq 0 ]; then
    die "ComfyUI has 0 workflows but the repo has $dest_n. Refusing to delete them (use --force if that's intended)."
  fi
  sync_dir "$WORKFLOWS_SRC" "$dest"
  ok "Workflows: $src_n file(s)"
}

backup_workspace() {
  local dest="$REPO_DIR/workspace"
  # The workflows subfolder is backed up separately; the rest of
  # user/default is settings, templates, keybindings, subgraphs, etc.
  sync_dir "$USER_DEFAULT" "$dest/user-default" --exclude=/workflows/
  if [ -f "$COMFY/extra_model_paths.yaml" ]; then
    [ "$DRY_RUN" -eq 1 ] || cp "$COMFY/extra_model_paths.yaml" "$dest/extra_model_paths.yaml"
  fi
  ok "Workspace settings"

  local big
  big="$(find "$USER_DEFAULT" -type f -size +10M 2>/dev/null || true)"
  [ -n "$big" ] && warn "Large files (>10 MB) in user/default, consider excluding them:"$'\n'"$big"
  return 0
}

backup_custom_nodes() {
  local dest="$REPO_DIR/custom-nodes" d remote rev list=""
  [ -d "$COMFY/custom_nodes" ] || return 0

  # Plain list (works without ComfyUI-Manager): name, git remote, commit.
  for d in "$COMFY"/custom_nodes/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    case "$(basename "$d")" in __pycache__) continue ;; esac
    if [ -d "$d/.git" ]; then
      remote="$(git -C "$d" remote get-url origin 2>/dev/null || echo '-')"
      rev="$(git -C "$d" rev-parse HEAD 2>/dev/null || echo '-')"
    else
      remote="-"; rev="-"
    fi
    list="$list$(basename "$d") $remote $rev"$'\n'
  done

  if [ "$DRY_RUN" -eq 1 ]; then
    ok "Custom nodes (dry run, not written)"
    return
  fi

  mkdir -p "$dest"
  printf '%s' "$list" > "$dest/nodes.txt"

  # Restorable snapshot (nodes + pip packages) via comfy-cli / ComfyUI-Manager.
  if command -v comfy >/dev/null 2>&1 && \
     comfy --skip-prompt --workspace "$COMFY" node save-snapshot \
       --output "$dest/snapshot.json" >/dev/null 2>&1; then
    ok "Custom nodes: nodes.txt + snapshot.json"
  else
    warn "Couldn't save snapshot.json (needs comfy-cli and ComfyUI-Manager). Saved nodes.txt only."
  fi
}

backup_models_list() {
  local models="$COMFY/${L_MODELS_SUBDIR}"
  [ "$L_MODELS_SUBDIR" = "unknown" ] && models="$COMFY/models"
  [ -d "$models" ] || return 0
  [ "$DRY_RUN" -eq 1 ] && return 0
  mkdir -p "$REPO_DIR/models"
  {
    echo "# Model files present in $models (generated by scripts/backup.sh)."
    echo "# Sizes only; add download links in other files in this folder."
    (cd "$models" && { find -L . -type f ! -name 'put_*_here' ! -name '.DS_Store' 2>/dev/null || true; } \
      | sed 's|^\./||' | sort | while IFS= read -r f; do
          printf '%s\t%s\n' "$(du -hL "$f" | cut -f1)" "$f"
        done)
  } > "$REPO_DIR/models/installed.txt"
  ok "Models list"
}

# ---------------------------------------------------------------------------
# Secrets + git
# ---------------------------------------------------------------------------

# Stops the commit if something that looks like a key or token got copied in.
scan_for_secrets() {
  local hits
  hits="$(cd "$REPO_DIR" && grep -rIinoE \
      -e 'hf_[A-Za-z0-9]{30,}' \
      -e 'sk-[A-Za-z0-9_-]{20,}' \
      -e 'comfyui-[A-Za-z0-9]{30,}' \
      -e 'gh[pousr]_[A-Za-z0-9]{30,}' \
      -e '"[A-Za-z_.]*(api[_-]?key|apikey|token|secret|password)[A-Za-z_.]*" *: *"[^"]{12,}"' \
      workflows workspace custom-nodes 2>/dev/null \
    | cut -d: -f1,2 | sort -u || true)"
  if [ -n "$hits" ]; then
    warn "Possible API keys/tokens found (file:line):"
    printf '%s\n' "$hits" | sed 's/^/    /' >&2
    die "Not committing. Remove them from ComfyUI's settings/workflows, or commit by hand if they're false positives."
  fi
}

commit_and_push() {
  git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "$REPO_DIR is not a git repo. Run: git -C \"$REPO_DIR\" init"

  scan_for_secrets

  git -C "$REPO_DIR" add -A
  if git -C "$REPO_DIR" diff --cached --quiet; then
    ok "No changes since last backup"
    return
  fi

  info "Changes:"
  git -C "$REPO_DIR" diff --cached --stat | sed 's/^/  /'
  git -C "$REPO_DIR" commit -q -m "backup: $(date '+%Y-%m-%d %H:%M') (ComfyUI $L_VERSION)"
  ok "Committed"

  if [ "$DO_PUSH" -eq 1 ]; then
    if git -C "$REPO_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
      git -C "$REPO_DIR" push -q && ok "Pushed"
    else
      info "${C_DIM}No upstream branch set, skipping push.${C_OFF}"
    fi
  fi
}

# ---------------------------------------------------------------------------

for tool in git rsync find sed; do
  command -v "$tool" >/dev/null 2>&1 || die "Missing required tool: $tool"
done

RUNNING_DIR=""
detect_running

FOUND_DIR=""; FOUND_SOURCE=""
find_comfy_dir
COMFY="$FOUND_DIR"
info "ComfyUI: $COMFY ${C_DIM}($FOUND_SOURCE)${C_OFF}"

# Only honour the running server's directory flags if it's the same install.
if [ "$RUNNING_DIR" != "$COMFY" ]; then
  USER_DIR_OVERRIDE=""; BASE_DIR_OVERRIDE=""
fi

read_layout

if [ -n "$USER_DIR_OVERRIDE" ]; then
  USER_ROOT="$(expand_path "$USER_DIR_OVERRIDE")"
  info "Using --user-directory from the running server: $USER_ROOT"
elif [ -n "$BASE_DIR_OVERRIDE" ]; then
  USER_ROOT="$(expand_path "$BASE_DIR_OVERRIDE")/$L_USER_SUBDIR"
  info "Using --base-directory from the running server: $USER_ROOT"
else
  USER_ROOT="$COMFY/$L_USER_SUBDIR"
fi
USER_DEFAULT="$USER_ROOT/$L_DEFAULT_USER"
WORKFLOWS_SRC="$USER_DEFAULT/workflows"

NEW_LAYOUT="$(mktemp)"
trap 'rm -f "$NEW_LAYOUT"' EXIT
write_layout > "$NEW_LAYOUT"
check_layout

[ "$DRY_RUN" -eq 1 ] && info "${C_YEL}Dry run: nothing will be written.${C_OFF}"

backup_workflows
backup_workspace
backup_custom_nodes
backup_models_list

if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$(dirname "$LAYOUT_FILE")"
  cp "$NEW_LAYOUT" "$LAYOUT_FILE"
fi

if [ "$DO_COMMIT" -eq 1 ]; then
  commit_and_push
else
  info "${C_DIM}Skipping commit.${C_OFF}"
fi
