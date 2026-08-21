# BenQ Display Pilot 2 — DisplayPort DDC/CI fix (amdgpu)

Fix for BenQ Display Pilot 2 (Linux AppImage, tested with v1.1.4.0) failing to control a
monitor connected over **DisplayPort** on an AMD GPU (`amdgpu` driver), while working fine
over HDMI on the same machine.

Tested on Ubuntu 24.04 with a BenQ RD270Q monitor, but the root cause is a generic
`amdgpu`/DRM sysfs quirk, not specific to this monitor model.

## Symptom

Display Pilot 2 can't read/write any VCP setting (brightness, input source, etc.) on a
monitor connected via DisplayPort. It typically fails with something like "failed to open
bus" internally. The exact same monitor works fine when connected via HDMI instead.

## Root cause

On `amdgpu`, a DisplayPort connector exposes DDC/CI (the monitor control protocol) over a
separate **AUX** i2c bus, nested under the connector's own sysfs directory:

```
/sys/class/drm/cardX-DP-N/i2c-M       <- AUX bus, sysfs name "AMDGPU DM aux hw bus N", WORKS
```

But the connector's top-level `ddc` symlink — the "standard" way apps are supposed to find
the DDC bus — points somewhere else, at a **legacy** i2c bus that is dead/unused for
DP-native connections:

```
/sys/class/drm/cardX-DP-N/ddc -> ../../../i2c-K   <- sysfs name "AMDGPU DM i2c hw bus N", DEAD
```

Display Pilot 2 (like a number of other DDC/CI tools, e.g. older `ddcutil`/`ddccontrol`
versions before they added amdgpu-specific handling) naively follows `ddc` and gets the
non-functional bus, so every VCP read/write fails. HDMI connectors don't have this AUX/DDC
split, which is why HDMI works and DP doesn't.

**Confirmed fix:** bind-mount the working AUX bus device node onto the dead DDC bus device
node before launching the app:

```bash
sudo mount --bind /dev/i2c-M /dev/i2c-K   # AUX onto DDC
```

Both bus numbers (`M`, `K` above) are **not stable** — they depend on GPU/connector
enumeration order and can shift across reboots, driver updates, or hotplug. This repo
contains a script that re-detects both numbers fresh on every launch instead of hardcoding
them.

## How to check if this affects you

```bash
# find your connected DP connector
for c in /sys/class/drm/card*-DP-*; do echo "$c: $(cat "$c/status" 2>/dev/null)"; done

# for the connected one, compare:
readlink -f /sys/class/drm/cardX-DP-N/ddc        # -> .../i2c-K  (check its sysfs "name" file)
ls /sys/class/drm/cardX-DP-N/ | grep '^i2c-'       # -> i2c-M     (check its sysfs "name" file)
cat /sys/class/i2c-dev/i2c-K/name  /sys/class/i2c-dev/i2c-M/name
# or: cat /sys/bus/i2c/devices/i2c-K/name  /sys/bus/i2c/devices/i2c-M/name
```

If `i2c-K` (the `ddc` target) reports `AMDGPU DM i2c hw bus N` and `i2c-M` (nested under the
connector) reports `AMDGPU DM aux hw bus N`, and `K != M`, you're hitting the same bug.

## What's in this repo

| File | Purpose |
|---|---|
| [`dp-display-pilot-2.sh`](dp-display-pilot-2.sh) | Launcher script: auto-detects the connector/buses, bind-mounts AUX onto DDC, launches the AppImage, unmounts on exit. |
| [`display-pilot-2.desktop.template`](display-pilot-2.desktop.template) | `.desktop` launcher template (`@HOME@` placeholder, filled in by `install.sh`). |
| [`sudoers.d/dp-display-pilot-2.example`](sudoers.d/dp-display-pilot-2.example) | Sudoers rule content + full rationale — **not** installed automatically. |
| [`install.sh`](install.sh) | Installs the script + desktop entry + icon for the current user; idempotent, safe to re-run. |

## Install

```bash
git clone <this-repo-url>
cd benq-displaypilot2-dp-fix
./install.sh                                   # auto-detects the AppImage under ~/.local/bin or ~/Applications
# or, if it's somewhere else:
./install.sh /path/to/DisplayPilot2.AppImage
```

This copies the launcher to `~/.local/bin/dp-display-pilot-2.sh`, extracts the app icon from
the AppImage into `~/.local/share/icons/`, and generates
`~/.local/share/applications/display-pilot-2.desktop` pointing at the script instead of the
AppImage directly.

**One manual step is required** — the script needs passwordless `sudo` for `mount --bind` /
`umount` on i2c device nodes (see [Sudoers setup](#sudoers-setup) below); `install.sh` prints
the exact line to add but does not touch `/etc/sudoers.d` itself.

## Sudoers setup

```bash
sudo visudo -f /etc/sudoers.d/dp-display-pilot-2
```

Add (replace `YOUR_USERNAME`):

```
YOUR_USERNAME ALL=(root) NOPASSWD: /usr/bin/mount ^--bind /dev/i2c-[0-9]+ /dev/i2c-[0-9]+$, /usr/bin/umount ^/dev/i2c-[0-9]+$
```

**Why not a plain `/dev/i2c-*` wildcard?** Per `man sudoers`, a `*` wildcard in *command
arguments* (unlike in the command path) also matches `/` and whitespace, so
`mount --bind /dev/i2c-* /dev/i2c-*` would also match e.g.
`mount --bind /dev/i2c-6/../../etc/shadow /dev/i2c-8/../../root/.ssh/authorized_keys` — a full
path-traversal root exploit disguised as an i2c bind mount. The rule above uses an anchored
POSIX-ERE regex instead (sudoers regex mode triggers only when the *entire* argument string
begins with `^` — including the literal `--bind`, which is why `^` comes before it, not after)
so `[0-9]+` can never match `/` or `..`.

**Residual tradeoff:** the rule still authorizes bind-mounting *any* `/dev/i2c-N` onto *any
other* `/dev/i2c-N`, not just today's specific pair — because bus numbers aren't stable across
reboots, so a hardcoded rule would break itself on the next reboot. The blast radius is bounded
to i2c character-device nodes only (no path escape), but a bug or misuse could still bind-mount
over an unrelated i2c bus in use by something else (e.g. a hwmon sensor), recoverable with
`umount` or a reboot. See `sudoers.d/dp-display-pilot-2.example` for the full writeup.

## Manual test

```bash
~/.local/bin/dp-display-pilot-2.sh
```

Expected log output (numbers will vary by machine):

```
[dp-display-pilot-2] Using AppImage: /home/you/.local/bin/DisplayPilot2.AppImage
[dp-display-pilot-2] Connected DP connector: card1-DP-1
[dp-display-pilot-2] DDC (legacy, dead): /dev/i2c-6   AUX (working): /dev/i2c-10
[dp-display-pilot-2] Bind-mounting /dev/i2c-10 onto /dev/i2c-6 ...
[dp-display-pilot-2] Bind mount OK.
[dp-display-pilot-2] Launching Display Pilot 2 (QT_QPA_PLATFORM=xcb) ...
```

While the app is running: `mount | grep i2c-6` should show the bind mount. After quitting the
app (normal exit, or Ctrl+C): it should be gone again, and the log should show `Unmounting
bind mount on /dev/i2c-...`.

With the monitor on HDMI (or no DP connector plugged in), the script logs "No connected
DisplayPort connector found" and launches normally without attempting a mount.

## Troubleshooting

- **Still prompts for a sudo password** — the sudoers rule doesn't match. Test directly:
  `sudo -n mount --bind /dev/i2c-10 /dev/i2c-6 && echo OK` (use your real bus numbers). If it
  still prompts, re-check the rule with `sudo visudo -c` and make sure `^` comes right before
  `--bind`, not after it.
- **"a password is required" even with the rule installed** — run `sudo -l` and confirm the
  rule shows up; a stray space or missing `^`/`$` is the usual culprit.
- **Bind mount fails outright** — check `journalctl -t sudo` for the denial reason.
- **Script logs "no nested i2c-* AUX bus found" or "ddc is not a symlink"** — your kernel/amdgpu
  version may lay out sysfs differently than what this was built against. Run
  `ls -la /sys/class/drm/card*-DP-*/` yourself and compare against the [Root cause](#root-cause)
  section above.
- **Wrong bus pair after a reboot** — expected and handled: the script re-detects both buses on
  every run, it never hardcodes numbers.
- **Multiple monitors connected, picks the wrong one** — the script greps each connected DP
  connector's EDID for `RD270Q` and prefers that match, falling back to the first connected
  connector otherwise. If you're not using an RD270Q, change the `grep -q "RD270Q"` line in
  `dp-display-pilot-2.sh` to match your own monitor's model string (find it via
  `strings /sys/class/drm/cardX-DP-N/edid`).

## Why this exists

Written up so the fix survives a fresh Ubuntu install (just `git clone` + `./install.sh` +
one `visudo` line) and can be shared with anyone else hitting the same amdgpu DP/DDC-AUX bug
with Display Pilot 2 or similar DDC/CI tools.

## License

MIT — see [LICENSE](LICENSE).
