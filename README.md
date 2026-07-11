# FanControl

Minimal macOS menu bar app for controlling Mac fans with presets. No sensors list, no RPM readouts in the menu, no sponsor links — just presets and quit.

## Menu

- Auto — SMC manages fan speed (default)
- Silent — minimum RPM
- Balanced — 35% of the min..max range
- Performance — 65%
- Max — 100%
- Quit — restores Auto before exiting

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
fanctl auto         # back to automatic
```

## Uninstall

```sh
sudo make uninstall
```

## Notes

- Quit any other fan control app (e.g. MacFansControl) first — two apps fighting over the SMC gives confusing results.
- If the app quits unexpectedly while a preset is forced, fans stay forced until reboot or `fanctl auto`.
