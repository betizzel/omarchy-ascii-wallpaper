#!/bin/bash
# Helper for the ascii-wallpaper plugin: wires/unwires the menu entry in
# ~/.config/omarchy/extensions/omarchy-menu.jsonc and cleans up on unload.

set -uo pipefail

readonly plugin_id="betim.ascii-wallpaper"
readonly plugin_dir="$HOME/.config/omarchy/plugins/$plugin_id"
readonly state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/ascii-wallpaper"
readonly cleanup_helper="$state_dir/cleanup"
readonly menu_file="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
readonly menu_entry_id="style.asciiwallpaper"
# The exact line this plugin writes; only a line identical to it is ours to
# replace or remove. The icon is U+F120 spelled as UTF-8 bytes so the result
# does not depend on the locale.
readonly menu_icon=$'\xef\x84\xa0'
readonly menu_entry="  \"$menu_entry_id\": {\"icon\":\"$menu_icon\",\"label\":\"ASCII Wallpaper\",\"aliases\":[\"ascii\",\"asciiwallpaper\",\"ascii-wallpaper\"],\"description\":\"Convert a video into an ASCII-art wallpaper in theme colors\",\"action\":\"omarchy-launch-floating-terminal-with-presentation $plugin_dir/ascii-wallpaper-menu\"},"

wire_menu() {
  python3 - "$menu_file" "$menu_entry" <<'PY'
import re, shutil, sys, os, tempfile

# Resolve symlinks: a menu linked in from a dotfiles repo is edited in place,
# not replaced by a regular file.
path, entry = os.path.realpath(sys.argv[1]), sys.argv[2]

text = ""
if os.path.exists(path):
    with open(path) as f:
        text = f.read()

ENTRY = '"style.asciiwallpaper"'
lines = text.splitlines()
# Ours = a line identical to what this plugin writes. Any other line starting
# with our key was hand-edited or written by someone else: keep it as-is.
out, replaced, foreign = [], False, False
for line in lines:
    stripped = line.strip()
    if stripped == entry.strip():
        if not replaced:
            out.append(entry)
            replaced = True
        continue  # drop duplicate copies of our own entry
    if stripped.startswith(ENTRY):
        foreign = True
    out.append(line)

if not replaced and foreign:
    print(f"ascii-wallpaper: {path} already has a {ENTRY} entry this plugin "
          "did not write; leaving it alone", file=sys.stderr)
    sys.exit(0)

if not replaced:
    # Our line goes right after the '{' that opens the top-level object. Skip
    # the whitespace and comments before it: a '{' inside a leading comment
    # isn't the object, and the object may close on the same line ("{}").
    body = "\n".join(out)
    i = 0
    while i < len(body):
        if body[i].isspace() or body[i] == "\ufeff":
            i += 1
        elif body.startswith("//", i):
            j = body.find("\n", i)
            i = len(body) if j < 0 else j
        elif body.startswith("/*", i) and "*/" in body[i + 2:]:
            i = body.index("*/", i + 2) + 2
        else:
            break
    if i == len(body):  # no file, or only whitespace and comments
        out = (out if body.strip() else []) + ["{", entry, "}"]
    elif body[i] == "{":
        row = body.count("\n", 0, i)
        col = i - body.rfind("\n", 0, i) - 1
        rest = out[row][col + 1:].strip()
        if not rest or rest.startswith("//"):
            out.insert(row + 1, entry)
        else:  # "{}" or "{ ...entries }" on one line: split after the brace
            out[row:row + 1] = [out[row][:col + 1], entry, rest]
    else:
        print(f"ascii-wallpaper: {path} is not a JSONC object; leaving it alone",
              file=sys.stderr)
        sys.exit(0)

os.makedirs(os.path.dirname(sys.argv[1]), exist_ok=True)  # not where a broken link points
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".omarchy-menu.", suffix=".tmp")
with os.fdopen(fd, "w") as f:
    f.write("\n".join(out) + "\n")
if os.path.exists(path):
    shutil.copymode(path, tmp)  # mkstemp is 0600; keep the menu's own mode
os.replace(tmp, path)
PY
  omarchy menu refresh >/dev/null 2>&1 || true
}

unwire_menu() {
  [[ -f $menu_file ]] || return 0
  python3 - "$menu_file" "$menu_entry" <<'PY' || return 1
import shutil, sys, os, tempfile

path, entry = os.path.realpath(sys.argv[1]), sys.argv[2]  # keep symlinks intact
with open(path) as f:
    lines = f.read().splitlines()

# Only remove a line identical to what this plugin writes. Anything else
# carrying our key (hand-edited, reformatted, or another extension's entry) is
# left alone -- a stale menu row is recoverable, a clobbered user entry is not.
out = [line for line in lines if line.strip() != entry.strip()]
if len(out) == len(lines):
    sys.exit(0)  # nothing of ours in the file; don't rewrite it

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".omarchy-menu.", suffix=".tmp")
with os.fdopen(fd, "w") as f:
    f.write("\n".join(out) + "\n")
shutil.copymode(path, tmp)  # mkstemp is 0600; keep the menu's own mode
os.replace(tmp, path)
PY
  omarchy menu refresh >/dev/null 2>&1 || true
}

prepare_cleanup_helper() {
  mkdir -p -m 0700 "$state_dir" 2>/dev/null || return 1
  [[ -L $state_dir ]] && return 1
  local tmp
  tmp=$(mktemp -p "$state_dir" .cleanup.XXXXXX) || return 1
  cp -f "$plugin_dir/ascii-wallpaper.sh" "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0755 "$tmp"
  mv -f "$tmp" "$cleanup_helper"
  chmod 0755 "$cleanup_helper" 2>/dev/null || true
}

cleanup_after_unload() {
  # Called detached right before the shell unloads the plugin. If the plugin
  # directory is gone (removed) or the plugin is disabled, drop the menu entry.
  for _ in {1..200}; do
    if [[ ! -d $plugin_dir ]]; then
      unwire_menu
      rm -rf "$state_dir"
      return 0
    fi
    sleep 0.01
  done

  local enabled
  enabled=$(omarchy plugin list --json 2>/dev/null \
    | jq -r --arg id "$plugin_id" '.[] | select(.id == $id) | .enabled' 2>/dev/null || true)
  if [[ $enabled == false ]]; then
    unwire_menu
  fi
}

case "${1:-}" in
  --wire-menu)
    prepare_cleanup_helper || true
    wire_menu
    ;;
  --unwire-menu)
    unwire_menu
    ;;
  --cleanup-after-unload)
    cleanup_after_unload
    ;;
  *)
    echo "usage: $0 [--wire-menu|--unwire-menu|--cleanup-after-unload]" >&2
    exit 2
    ;;
esac
