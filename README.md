# FanControl

Minimal macOS menu bar app for controlling Mac fans with presets. No sensors list, no RPM readouts in the menu, no sponsor links — just presets and quit.

## Menu

The menu bar item shows the average CPU temperature. The menu lists an Off
entry, then your presets, then:

- Off (macOS automatic) — hands the fans back to macOS/SMC automatic control; nothing is forced. Persisted like a preset.
- Edit Presets... — add, remove, rename, and reorder presets (drag rows to reorder). Each preset is either a fixed RPM or a temperature curve.
- Reset fans on sleep — when on (default), fans return to macOS automatic control on sleep/lid-close and the preset is re-applied on wake.
- Check for Updates... — queries GitHub Releases; if a newer version exists it downloads it, replaces the app in place, and relaunches.
- Quit — restores SMC automatic control before exiting

The active preset is re-asserted on a timer: if another controller or a
sleep/wake cycle drops the fans back to automatic, FanControl re-applies it
so the setting stays sticky instead of randomly dropping out.

Presets come in two kinds:

- Temperature curve (e.g. the default "Auto"): fans at hardware minimum at or below the min temp, hardware maximum at or above the max temp, linear in between. Default window: 50-75 C.
- Fixed RPM: forces all fans to a set RPM (clamped to each fan's hardware range).

Default presets (all editable): Auto (curve 50-75 C), Silent (2500 RPM), Balanced (4500 RPM), Performance (5000 RPM), Max (6800 RPM).

## How it works

- `FanControl.app` — menu bar app (AppKit, no dock icon)
- `fanctl` — CLI helper that talks to the SMC over IOKit. Writing fan keys requires root, so the installer places it at `/usr/local/bin/fanctl` with the setuid bit. Reads (`fanctl status`) work as any user.

Supports Apple Silicon and Intel (`flt`/`fpe2` fan key types, `F0Md`/`FS!` mode keys).

## Install

Download the release, unzip, and move `FanControl.app` to `/Applications`. On
first launch the app installs its `fanctl` helper (bundled inside the app) to
`/usr/local/bin/fanctl` with the setuid bit - macOS shows one administrator
prompt. Authorize it and the app can control fans. No build step needed.

### Build from source

```sh
make app            # build build/FanControl.app (fanctl bundled in Resources)
sudo make install   # optional: install fanctl (setuid root) + copy app to /Applications
```

Building yourself is optional - a release `FanControl.app` self-installs the
helper. `make install` is only a convenience for developers.

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

- Quit any other fan control app (e.g. Macs Fan Control) first — two apps fighting over the SMC gives confusing results. A second app writing fan keys gets `SMC ... result 130` (bad argument); the app now flags this and tells you to quit the other app.
- If the app quits unexpectedly while a preset is forced, fans stay forced until reboot or `fanctl auto`.
