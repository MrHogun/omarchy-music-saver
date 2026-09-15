#!/usr/bin/env bash
# Install Music Saver into Omarchy's plugin directory and enable it.
#
# Everything lives under ~/.config/omarchy/plugins/, so this needs no root and
# uninstalling is a matter of removing that one directory.
set -euo pipefail

ID=mrhogun.music-saver
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$ID"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${1:-install} == uninstall ]] && {
  omarchy plugin disable "$ID" 2>/dev/null || true
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
info "Enabled. Load it with: omarchy restart shell"
info "Then try it without waiting for the idle timer: omarchy-shell music-saver show"
