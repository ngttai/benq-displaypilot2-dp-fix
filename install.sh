#!/usr/bin/env bash
#
# install.sh - installs the BenQ Display Pilot 2 DisplayPort/DDC fix for the
# current user. Safe to re-run (idempotent).
#
# Usage: ./install.sh [path-to-DisplayPilot2.AppImage]
#
# What it does:
#   1. Copies dp-display-pilot-2.sh to ~/.local/bin/ and makes it executable.
#   2. Extracts the app icon from the AppImage (if found) into
#      ~/.local/share/icons/BenQDisplayPilot.svg.
#   3. Generates ~/.local/share/applications/display-pilot-2.desktop from the
#      template, with @HOME@ substituted for the real home directory.
#   4. Prints (but does NOT install) the sudoers line you need to add
#      yourself via `visudo` - see README.md and sudoers.d/dp-display-pilot-2.example.
#
# It does NOT touch /etc/sudoers.d - that step is manual and reviewed by you.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '[install] %s\n' "$*"; }
die() { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }

# --- 1. Locate the AppImage ------------------------------------------------
APPIMAGE="${1:-}"
if [ -z "$APPIMAGE" ]; then
	for c in "$HOME/.local/bin/DisplayPilot2.AppImage" "$HOME/Applications/"*.AppImage; do
		if [ -x "$c" ]; then APPIMAGE="$c"; break; fi
	done
fi
if [ -z "$APPIMAGE" ] || [ ! -x "$APPIMAGE" ]; then
	log "WARNING: could not auto-detect the Display Pilot 2 AppImage."
	log "  Place it at ~/.local/bin/DisplayPilot2.AppImage, or re-run:"
	log "  ./install.sh /path/to/DisplayPilot2.AppImage"
	log "  Continuing without icon extraction; the launcher script itself will still work."
fi

# --- 2. Install the launcher script -----------------------------------------
mkdir -p "$HOME/.local/bin"
install -m 755 "$SCRIPT_DIR/dp-display-pilot-2.sh" "$HOME/.local/bin/dp-display-pilot-2.sh"
log "Installed $HOME/.local/bin/dp-display-pilot-2.sh"

# --- 3. Extract the icon from the AppImage (best effort) -------------------
mkdir -p "$HOME/.local/share/icons"
ICON_DEST="$HOME/.local/share/icons/BenQDisplayPilot.svg"
if [ -n "$APPIMAGE" ] && [ -x "$APPIMAGE" ]; then
	EXTRACT_DIR=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$EXTRACT_DIR'" EXIT
	(
		cd "$EXTRACT_DIR"
		"$APPIMAGE" --appimage-extract >/dev/null 2>&1 || true
	)
	FOUND_ICON=$(find "$EXTRACT_DIR/squashfs-root" -maxdepth 1 \( -iname '*.svg' -o -iname '.DirIcon' \) 2>/dev/null | head -n1)
	if [ -z "$FOUND_ICON" ]; then
		# .DirIcon is often a relative symlink into usr/share/icons/...
		FOUND_ICON=$(find "$EXTRACT_DIR/squashfs-root" -path '*/icons/*' -iname '*.svg' 2>/dev/null | head -n1)
	fi
	if [ -n "$FOUND_ICON" ] && [ -r "$FOUND_ICON" ]; then
		cp "$FOUND_ICON" "$ICON_DEST"
		chmod 644 "$ICON_DEST"
		log "Extracted icon to $ICON_DEST"
	else
		log "WARNING: could not extract an icon from the AppImage; desktop entry will use a generic icon name instead."
		ICON_DEST="video-display"
	fi
else
	ICON_DEST="video-display"
fi

# --- 4. Generate the .desktop launcher --------------------------------------
mkdir -p "$HOME/.local/share/applications"
DESKTOP_DEST="$HOME/.local/share/applications/display-pilot-2.desktop"
sed "s#@HOME@#$HOME#g" "$SCRIPT_DIR/display-pilot-2.desktop.template" > "$DESKTOP_DEST"
if [ "$ICON_DEST" = "video-display" ]; then
	sed -i "s#^Icon=.*#Icon=video-display#" "$DESKTOP_DEST"
fi
chmod 644 "$DESKTOP_DEST"
log "Installed $DESKTOP_DEST"

if command -v desktop-file-validate >/dev/null; then
	desktop-file-validate "$DESKTOP_DEST" && log "Desktop file validated OK."
fi
if command -v update-desktop-database >/dev/null; then
	update-desktop-database "$HOME/.local/share/applications" && log "Desktop database refreshed."
fi

# --- 5. Sudoers reminder ------------------------------------------------------
cat <<EOF

[install] Done. One manual step remains (not automated on purpose):

  sudo visudo -f /etc/sudoers.d/dp-display-pilot-2

Add this line (replace $USER if installing for a different user):

  $USER ALL=(root) NOPASSWD: /usr/bin/mount ^--bind /dev/i2c-[0-9]+ /dev/i2c-[0-9]+\$, /usr/bin/umount ^/dev/i2c-[0-9]+\$

See sudoers.d/dp-display-pilot-2.example and README.md for the full explanation
of why the rule is written this way.

Test manually before relying on the desktop launcher:
  ~/.local/bin/dp-display-pilot-2.sh
EOF
