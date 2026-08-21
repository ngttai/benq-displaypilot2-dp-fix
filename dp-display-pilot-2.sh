#!/usr/bin/env bash
#
# dp-display-pilot-2.sh
#
# Launcher for BenQ Display Pilot 2 that works around an amdgpu bug: for
# DisplayPort-connected monitors, the connector's `ddc` sysfs symlink points
# at a dead legacy i2c bus ("AMDGPU DM i2c hw bus N") instead of the working
# DP AUX bus ("AMDGPU DM aux hw bus N") that actually carries DDC/CI. This
# script auto-detects both buses for whichever DP connector is connected and
# bind-mounts the working AUX device onto the dead DDC device node before
# launching the app, undoing the mount on exit.
#
# Usage: dp-display-pilot-2.sh [path-to-AppImage]

set -uo pipefail

log() {
	printf '[dp-display-pilot-2] %s\n' "$*" >&2
}

die() {
	log "ERROR: $*"
	exit 1
}

# --- 1. Resolve the AppImage path ---------------------------------------
APPIMAGE="${1:-}"
if [ -z "$APPIMAGE" ]; then
	if [ -x "$HOME/.local/bin/DisplayPilot2.AppImage" ]; then
		APPIMAGE="$HOME/.local/bin/DisplayPilot2.AppImage"
	else
		# fall back to any single AppImage under ~/Applications
		shopt -s nullglob
		candidates=("$HOME/Applications/"*.AppImage)
		shopt -u nullglob
		if [ "${#candidates[@]}" -ge 1 ]; then
			APPIMAGE="${candidates[0]}"
		fi
	fi
fi

if [ -z "$APPIMAGE" ] || [ ! -x "$APPIMAGE" ]; then
	die "could not find a Display Pilot 2 AppImage (looked for ~/.local/bin/DisplayPilot2.AppImage and ~/Applications/*.AppImage). Pass its path as an argument."
fi

log "Using AppImage: $APPIMAGE"

# --- 2. Find connected DP connectors ------------------------------------
DRM_DIR=/sys/class/drm
candidates=()
for conn in "$DRM_DIR"/card*-DP-*; do
	[ -e "$conn/status" ] || continue
	status=$(cat "$conn/status" 2>/dev/null || true)
	if [ "$status" = "connected" ]; then
		candidates+=("$conn")
	fi
done

CONN=""
if [ "${#candidates[@]}" -eq 0 ]; then
	log "No connected DisplayPort connector found (monitor likely on HDMI) - launching without bind mount."
elif [ "${#candidates[@]}" -eq 1 ]; then
	CONN="${candidates[0]}"
	log "Connected DP connector: $(basename "$CONN")"
else
	log "Multiple connected DP connectors found; looking for RD270Q via EDID..."
	for c in "${candidates[@]}"; do
		if [ -r "$c/edid" ] && strings "$c/edid" 2>/dev/null | grep -q "RD270Q"; then
			CONN="$c"
			log "Matched RD270Q on $(basename "$CONN")"
			break
		fi
	done
	if [ -z "$CONN" ]; then
		CONN="${candidates[0]}"
		log "WARNING: no connector's EDID matched RD270Q; falling back to first connected: $(basename "$CONN")"
	fi
fi

# --- 3. Resolve the DDC (legacy) and AUX (working) i2c buses -----------
DDC_DEV=""
AUX_DEV=""
if [ -n "$CONN" ]; then
	if [ -L "$CONN/ddc" ]; then
		ddc_real=$(readlink -f "$CONN/ddc")
		DDC_DEV="/dev/$(basename "$ddc_real")"
	else
		log "WARNING: $(basename "$CONN")/ddc is not a symlink; cannot determine legacy DDC bus."
	fi

	# NOTE: $CONN is itself a symlink (e.g. /sys/class/drm/card1-DP-1 ->
	# .../drm/card1/card1-DP-1), and `find` does not descend into a
	# symlinked starting path the way `ls` does - it returns nothing even
	# with -type d and no name filter. Use `ls` instead.
	aux_name=$(ls -1 "$CONN/" 2>/dev/null | grep '^i2c-' | head -n1)
	if [ -n "$aux_name" ]; then
		AUX_DEV="/dev/$aux_name"
	else
		log "WARNING: no nested i2c-* AUX bus found under $(basename "$CONN")."
	fi
fi

# --- 4. Bind mount AUX onto DDC, with cleanup on exit -------------------
DID_MOUNT=0
cleanup() {
	if [ "$DID_MOUNT" -eq 1 ]; then
		log "Unmounting bind mount on $DDC_DEV"
		if ! sudo umount "$DDC_DEV" 2>&1 | while IFS= read -r line; do log "umount: $line"; done; then
			log "WARNING: failed to unmount $DDC_DEV (it may already be unmounted)."
		fi
	fi
}
trap cleanup EXIT INT TERM

if [ -n "$DDC_DEV" ] && [ -n "$AUX_DEV" ] && [ "$DDC_DEV" != "$AUX_DEV" ]; then
	log "DDC (legacy, dead): $DDC_DEV   AUX (working): $AUX_DEV"
	log "Bind-mounting $AUX_DEV onto $DDC_DEV ..."
	if sudo mount --bind "$AUX_DEV" "$DDC_DEV" 2>&1 | while IFS= read -r line; do log "mount: $line"; done; then
		DID_MOUNT=1
		log "Bind mount OK."
	else
		log "ERROR: bind mount failed. This is usually a sudo/permissions issue -"
		log "  check that a passwordless sudo rule for 'mount --bind'/'umount' on"
		log "  /dev/i2c-* device nodes is installed (see dp-display-pilot-2 sudoers"
		log "  drop-in) and that 'sudo -n true' succeeds without a password prompt."
		log "Continuing to launch Display Pilot 2 anyway - DDC/CI control will likely fail."
	fi
elif [ -n "$CONN" ]; then
	log "DDC and AUX bus already match, or one could not be resolved; no bind mount needed."
fi

# --- 5. Launch ------------------------------------------------------------
# QT_QPA_PLATFORM defaults to wayland: running under XWayland (xcb) caused
# Display Pilot 2's own output<->DRM-connector matching to mis-map a second
# (HDMI) monitor onto the DP connector's i2c bus, showing it as a duplicate
# "RD270Q" instead of the actual second monitor. Native wayland does not
# have this bug on this system. Overridable by the caller if needed, e.g.:
#   QT_QPA_PLATFORM=xcb ~/.local/bin/dp-display-pilot-2.sh
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland}"
log "Launching Display Pilot 2 (QT_QPA_PLATFORM=$QT_QPA_PLATFORM) ..."
"$APPIMAGE"
status=$?
log "Display Pilot 2 exited with status $status"
exit "$status"
