#!/usr/bin/env bash
# Install Music Saver into Omarchy's plugin directory and enable it.
#
# Everything lives under ~/.config/omarchy/plugins/, so this needs no root and
# uninstalling is a matter of removing that one directory.
set -euo pipefail

ID=mrhogun.music-saver
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy"
DEST="$CONFIG/plugins/$ID"

# Omarchy's menu is extended from one shared file, so this adds a marked block
# rather than rewriting it, and uninstall takes exactly that block back out.
#
# A new row can only ever land at the bottom of its submenu -- the menu merges
# Omarchy's rows first and appends the user's, so an extension does not get to
# pick a position -- and the bottom of System, under Shutdown, is not where
# this belongs. So the block reuses the Screensaver id and turns that row into
# a submenu, which is the one place a row of ours can appear next to it. The
# music entry hides itself when nothing is playing.
MENU="$CONFIG/extensions/omarchy-menu.jsonc"
MENU_BEGIN="// >>> $ID"
MENU_END="// <<< $ID"
read -r -d '' MENU_ROWS <<'ROWS' || true
  "system.screensaver": {"icon":"󱄄","label":"Screensaver"},
  "system.screensaver.default": {"icon":"󱄄","label":"Default","action":"omarchy-launch-screensaver force"},
  "system.screensaver.music": {"icon":"󰄨","label":"Musicsaver","description":"Album art and spectrum, while music is playing","action":"omarchy-shell music-saver show","when":"[ \"$(omarchy-shell music-saver playing)\" != 'nothing playing' ]"},
ROWS

menu_remove() {
  [[ -f $MENU ]] || return 0
  sed -i "\|$MENU_BEGIN|,\|$MENU_END|d" "$MENU"
}

menu_add() {
  mkdir -p "$(dirname "$MENU")"
  [[ -f $MENU ]] || printf '{\n}\n' >"$MENU"
  menu_remove
  # After the opening brace, so the row is valid whether or not the user has
  # entries of their own. Omarchy strips trailing commas, so one is always safe.
  # Through the environment, not -v: awk expands backslash escapes in a -v
  # value, which would eat the \" that keeps the row valid JSON.
  MENU_BEGIN="$MENU_BEGIN" MENU_ROWS="$MENU_ROWS" MENU_END="$MENU_END" \
  awk '
    !placed && /^[[:space:]]*\{/ {
      print
      print ENVIRON["MENU_BEGIN"]
      print ENVIRON["MENU_ROWS"]
      print ENVIRON["MENU_END"]
      placed = 1
      next
    }
    { print }
  ' "$MENU" >"$MENU.tmp" && mv "$MENU.tmp" "$MENU"
}

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${1:-install} == uninstall ]] && {
  omarchy plugin disable "$ID" 2>/dev/null || true
  menu_remove
  rm -rf "$DEST"
  info "Removed. Restart the shell to unload it: omarchy restart shell"
  exit 0
}

command -v omarchy >/dev/null || die "Omarchy not found"
command -v pw-cat  >/dev/null || die "pw-cat not found -- install pipewire-audio (or pipewire-tools)"
command -v ffmpeg  >/dev/null || die "ffmpeg not found -- needed to read album art"
command -v python3 >/dev/null || die "python3 not found"

info "Installing to $DEST"
mkdir -p "$DEST/bin"
install -m644 "$SRC/manifest.json" "$SRC/Service.qml" "$DEST/"
install -m755 "$SRC/bin/art.py" "$SRC/bin/spectrum.py" "$DEST/bin/"

omarchy plugin enable "$ID" >/dev/null 2>&1 || true
menu_add
info "Added to the Omarchy menu: System > Screensaver > Music Saver"
info "Enabled. Load it with: omarchy restart shell"
info "Then try it without waiting for the idle timer: omarchy-shell music-saver show"
