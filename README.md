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
- **[linecast](https://github.com/ashuttl/linecast)** `2.2.0` installed and
  on your `PATH` — this is the exact release this plugin was last reviewed
  against (see [Security](#security) below); a different version isn't
  bundled, reviewed, or blocked, just flagged in the widget if it drifts.

  Recommended, hash-verified install (fails closed if PyPI ever serves
  different bytes for this release):

  ```bash
  pip install --user --require-hashes -r requirements-linecast.txt
  ```

  Quicker alternatives that pin the version but don't verify its hash:

  ```bash
  uv tool install linecast==2.2.0
  pipx install linecast==2.2.0
  pip install --user linecast==2.2.0
  ```

  Verify with `linecast --version`. This plugin will not work without it.

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

## Security

This plugin's own code (QML, JS, `ptyrun.py`) is auditable in this
repository; `linecast` itself is upstream code this plugin runs but does
not bundle, reimplement, or review. This section covers the actual
process, input, output, and file boundaries this plugin's code crosses,
and how the two are bound together.

### Backend binding

`linecast` is installed by the user, separately from this plugin, from
PyPI (see Requirements above) — the marketplace-reviewed commit of this
repository controls none of the bytes that actually run as the backend,
and a later `pip`/`pipx`/`uv` upgrade changes that silently. Two things
address that:

- **Hash-verified install**: `requirements-linecast.txt` pins the exact
  release this plugin was reviewed against (`2.2.0`) with the sha256
  hashes PyPI published for its sdist and wheel, installable with
  `pip install --require-hashes`.
- **Runtime drift check**: on open, the plugin runs `linecast --version`
  and compares it against that same reviewed version. A mismatch shows a
  banner in the popup naming both versions — informational, not a hard
  block, since this plugin can't enforce what a user has installed and
  refusing to run over an unrelated version bump would be worse than a
  visible warning.

### Process boundary (PTY)

Every `linecast <view> --live` process is spawned by `ptyrun.py` via
`os.fork()` + `os.execvp()` with a fixed argv — never a shell, never a
concatenated command string. `tabId` (the only variable part of that
argv) comes from this file's own hardcoded six-entry tab list
(`weather`/`radar`/`sunshine`/`moon`/`tides`/`maps`), not from anything a
user types. `weatherProc`'s one-shot `linecast weather --json` call is the
same: a plain argv list, no shell. `PR_SET_PDEATHSIG` plus `SIGTERM`/
`SIGHUP` handlers guarantee both `ptyrun.py` and the `linecast` child it
execs are killed on panel close, plugin disable, Quickshell exit, or a
hard kill — confirmed directly during development that without this,
killed sessions' process pairs were reparented to init and kept running
indefinitely.

### Input boundary

Keyboard events reach the running `linecast` process only through
`keyToBytes()`'s fixed switch-case (arrow keys, Enter, Backspace, Tab,
Page Up/Down, Home/End each map to one exact escape sequence) or, for
anything else, `event.text` filtered to printable characters
(`charCodeAt(0) >= 0x20`) — Escape is deliberately excluded so it always
closes the panel instead of reaching the pty. Mouse events are encoded as
fixed-format SGR sequences (`ESC[<btn;col;rowM`) with `col`/`row` computed
from cell geometry, never from unvalidated text. Both paths write straight
to the pty master fd (`Process.write()` / `os.write(master_fd, ...)`);
neither passes through a shell or an interpreter of any kind.

### Output boundary

`linecast`'s pty output is parsed by `Ansi.js` and painted by
`TermCanvas.qml`. The parser recognizes exactly one CSI terminator
(`m` — SGR color/bold) and treats every other CSI sequence
(cursor-move, erase-line/screen, private modes) as a no-op to discard;
nothing from that stream is ever `eval`'d, treated as HTML, or otherwise
interpreted as code — it becomes `ctx.fillText()`/`ctx.fillRect()` calls
on a `Canvas`, so there's no injection surface even if `linecast` (or a
process impersonating it) emitted adversarial bytes. `ptyrun.py`
additionally intercepts and answers only literal OSC 10/11/4 *query*
sequences itself (to supply Omarchy's theme colors); every other OSC
sequence passes through unmodified to the parser above, which discards it
the same way.

### File boundary

The only file this plugin's code reads is
`~/.local/state/omarchy/current/theme/colors.toml` — a fixed path under
the user's own state directory, parsed with a narrow key/value regex,
never executed or passed to a shell, and used only to answer OSC color
queries (see Output boundary). Neither `ptyrun.py` nor the QML/JS here
write, create, or delete any file. Removal (see above) only ever deletes
this plugin's own install directory.

## License

The code in this repository (the Omarchy plugin itself — QML, JS, and the
Python pty helper) is licensed under the [MIT License](LICENSE).

linecast itself is separately licensed (MIT) by Andrew Shuttleworth — see
[its repository](https://github.com/ashuttl/linecast) for its own license
terms. This plugin is not affiliated with or endorsed by linecast's author;
it's an independent companion built to embed linecast's output in the
Omarchy bar.
