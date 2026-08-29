# Linecast for Omarchy

A companion to Omarchy's built-in weather widget: shows the current
temperature in the bar, and opens all six of linecast's views — Weather,
Radar, Sunshine, Moon, Tides, and Maps — live and interactive in one
popup, right from the menu bar.

![Screenshot](screenshot.png)

## Credit

This plugin is a bar widget wrapper around **[linecast](https://github.com/ashuttl/linecast)**
by [Andrew Shuttleworth](https://github.com/ashuttl) (MIT licensed). All the
actual weather, radar, tide, sun, moon, and map data — and every bit of the
terminal rendering you see in the dashboard — comes from linecast. This
plugin doesn't reimplement any of that; it runs the real `linecast` CLI
in the background and replays its live terminal output onto a canvas inside
the Omarchy bar, with real keyboard and mouse input forwarded back into it.
None of linecast's code is bundled here — it's a required external
dependency you install separately (see below) — so full credit for
everything the dashboard actually shows belongs to linecast and its author.

If you find this useful, go star [linecast](https://github.com/ashuttl/linecast) too.

## Features

- **Bar pill**: current temperature + condition icon, refreshed periodically.
- **Click to open** one popup dashboard with all six of linecast's views —
  Weather, Radar, Sunshine, Moon, Tides, Maps — as tabs, each embedded
  and fully interactive right there; nothing opens in a separate window.
- **Actually live**, not a static snapshot — radar animation, live sun/moon
  position, etc., exactly like running `linecast` in a terminal.
- **Real interactivity**: keyboard shortcuts (e.g. radar's layer toggles
  and zoom, arrow-key time-scrubbing) and mouse — click, drag to pan,
  scroll to zoom on Maps — are forwarded into the running `linecast`
  process, not simulated.
- Renders at a fixed, uniform grid resolution so every tab looks consistent
  regardless of how much detail that particular view draws.

## Requirements

- [Omarchy](https://omarchy.org/) (Quickshell-based bar/shell)
- Python 3 (used only for a small pty-forwarding helper; no extra pip
  packages needed)
- **[linecast](https://github.com/ashuttl/linecast)** installed and on your `PATH`:

  ```bash
  # any of these work
  uv tool install linecast
  pipx install linecast
  pip install --user linecast
  ```

  Verify with `linecast --help`. This plugin will not work without it.

## Installation

```bash
omarchy plugin add https://github.com/JMThomas00/omarchy-linecast.git --enable
```

Or manually:

```bash
git clone https://github.com/JMThomas00/omarchy-linecast.git \
  ~/.config/omarchy/plugins/linecast
omarchy plugin enable jmthomas00.linecast center
```

Move it around the bar with `omarchy bar move jmthomas00.linecast --section <left|center|right>`.

## Removal

```bash
omarchy plugin remove jmthomas00.linecast
```

Or manually:

```bash
omarchy plugin disable jmthomas00.linecast
rm -rf ~/.config/omarchy/plugins/linecast
```

Neither path touches anything outside this plugin's own folder and bar
placement -- linecast itself (installed separately, see Requirements
above) is untouched either way; remove it the same way you installed it
(`uv tool uninstall linecast`, `pipx uninstall linecast`, etc.) if you no
longer want it either.

## Usage

- **Click** the temperature pill to open the dashboard.
- **Click a tab** to switch views — Radar is the default.
- **Scroll / drag / click** inside a tab the same way you would in a real
  terminal running that linecast view (e.g. drag to pan Maps, scroll to
  zoom).
- Keyboard shortcuts linecast itself defines (radar's `s`/`c`/`w` layer
  toggles, `+`/`-` zoom, arrow keys to scrub through time) work when a tab
  has focus — click into it first.
- The small ⟳ in the top-right of the dashboard restarts the current tab's
  view if it ever gets stuck.
- **Esc** closes the dashboard. Note: this always closes the dashboard
  first, rather than dismissing anything linecast itself has open (e.g.
  radar's `t` theme picker) — those don't currently render through this
  plugin, so avoid opening them; if one gets triggered by accident, the
  same key that opened it (or the ⟳ restart button) gets back out.

## How it works, briefly

`linecast <view> --live` needs a real terminal (it uses cbreak mode for
input), which isn't available when a process is spawned headless by a
shell like Quickshell. `ptyrun.py` opens and sizes a pty itself and execs
linecast attached to it, then relays bytes in both directions: linecast's
output is parsed (`Ansi.js`) and painted onto a `Canvas`
(`TermCanvas.qml`), and keyboard/mouse events from the popup are encoded
back as terminal input (arrow keys, SGR mouse sequences) and written to
the pty — so it behaves like an actual terminal, not a recording of one.

## License

The code in this repository (the Omarchy plugin itself — QML, JS, and the
Python pty helper) is licensed under the [MIT License](LICENSE).

linecast itself is separately licensed (MIT) by Andrew Shuttleworth — see
[its repository](https://github.com/ashuttl/linecast) for its own license
terms. This plugin is not affiliated with or endorsed by linecast's author;
it's an independent companion built to embed linecast's output in the
Omarchy bar.
