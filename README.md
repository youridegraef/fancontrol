# FanControl

Minimal macOS menu bar app for controlling Mac fans with presets. No sensors list, no RPM readouts in the menu, no sponsor links — just presets and quit.

## Menu

The menu bar item shows the average CPU temperature. Menu:

- Auto — app-managed curve (default): fans at hardware minimum at or below the min temp, hardware maximum at or above the max temp, linear in between. Default window: 50-75 C.
- Silent — 2500 RPM
- Balanced — 4500 RPM
- Performance — 5000 RPM
- Max — 6800 RPM
- Edit Presets... — change the Auto temperature window and preset RPMs (persisted)
- Quit — restores SMC automatic control before exiting

## How it works

- `FanControl.app` — menu bar app (AppKit, no dock icon)
- `fanctl` — CLI helper that talks to the SMC over IOKit. Writing fan keys requires root, so the installer places it at `/usr/local/bin/fanctl` with the setuid bit. Reads (`fanctl status`) work as any user.

Supports Apple Silicon and Intel (`flt`/`fpe2` fan key types, `F0Md`/`FS!` mode keys).

## Install

```sh
make app            # build build/FanControl.app
sudo make install   # install fanctl (setuid root) + copy app to /Applications
```

Then launch FanControl from /Applications.

## CLI usage

```sh
fanctl status       # show fans
fanctl set 50       # force all fans to 50% of their range
fanctl rpm 4500     # force all fans to a fixed RPM
fanctl temp         # average CPU temperature
fanctl auto         # back to automatic
```

## Uninstall

```sh
sudo make uninstall
```

## Notes

- Quit any other fan control app (e.g. MacFansControl) first — two apps fighting over the SMC gives confusing results.
- If the app quits unexpectedly while a preset is forced, fans stay forced until reboot or `fanctl auto`.
