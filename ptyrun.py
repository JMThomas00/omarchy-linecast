#!/usr/bin/env python3
# Runs a command attached to a real pty, sized to --cols/--rows, and relays
# its output byte-for-byte to our own stdout via raw os.write (no stdio
# buffering to fight). Exists because `script` assumes it has a controlling
# terminal of its own to relay through, which isn't true when spawned
# headless (no tty anywhere in the session) by a process manager like
# Quickshell — it silently produces nothing in that case. This wrapper only
# needs pty/fcntl/termios, so it opens and sizes the pty itself and never
# depends on inheriting a terminal.
#
# Also relays our own stdin to the pty, so a caller with a writable pipe to
# our stdin (Quickshell's Process.write()) can forward real keyboard/mouse
# input to the child -- what makes linecast's own interactivity (radar's
# theme/layer toggles, maps' pan and zoom) work instead of just watching a
# recording of it.
import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios

# linecast probes its terminal for the active colour theme via OSC 10/11/4
# queries (see its _theme.py) and falls back to a fixed dark palette when
# nothing answers -- which is always, here, since ptyrun's pty has no real
# terminal emulator on the other end to reply. We stand in for one: read
# Omarchy's current theme colors.toml and answer those queries ourselves,
# the same way a themed terminal would. linecast's own light/dark handling
# (is_light_theme(), etc.) then does the right thing automatically based on
# the luminance of whatever bg/fg we report -- we don't special-case light
# vs dark here at all. Only literal queries (ending in "?") are matched, so
# any other OSC traffic (hyperlinks, title-setting) passes through as-is.
_OSC_QUERY_RE = re.compile(rb"\x1b\](10|11|4;(\d{1,2}));\?(?:\x07|\x1b\\)")
_OMARCHY_COLORS_PATH = os.path.expanduser(
    "~/.local/state/omarchy/current/theme/colors.toml"
)


def _parse_colors_toml(path):
    kv = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                m = re.match(r'^(\w+)\s*=\s*"([^"]*)"', line)
                if m:
                    kv[m.group(1)] = m.group(2)
    except OSError:
        return None
    return kv


def _hex_to_rgb(value):
    if not value or not value.startswith("#") or len(value) != 7:
        return None
    try:
        return (int(value[1:3], 16), int(value[3:5], 16), int(value[5:7], 16))
    except ValueError:
        return None


def _load_omarchy_palette():
    """Return (fg, bg, [16 ansi rgb tuples]) from the active Omarchy theme,
    or None if colors.toml is missing or doesn't have what we need."""
    kv = _parse_colors_toml(_OMARCHY_COLORS_PATH)
    if kv is None:
        return None

    if "color0" in kv:
        # Older-style themes: direct ANSI color0-color15.
        ansi_keys = [f"color{i}" for i in range(16)]
    else:
        # Newer semantic themes: map named slots onto the standard 16 ANSI
        # colors the same way the spotify_player theme.toml generator does.
        ansi_keys = [
            "dark_background", "red", "green", "yellow", "blue", "magenta",
            "cyan", "light_foreground", "muted", "bright_red", "bright_green",
            "bright_yellow", "bright_blue", "bright_magenta", "bright_cyan",
            "bright_foreground",
        ]

    ansi = [_hex_to_rgb(kv.get(k)) for k in ansi_keys]
    fg = _hex_to_rgb(kv.get("foreground"))
    bg = _hex_to_rgb(kv.get("background"))
    if fg is None or bg is None or any(c is None for c in ansi):
        return None
    return fg, bg, ansi


def _answer_osc_queries(data, master_fd):
    """Reply to any OSC 10/11/4 colour queries found in `data` by writing
    responses back into master_fd (so linecast reads them as if a real
    terminal answered), and strip the queries out of what gets forwarded
    to our own stdout so they never show up as stray text."""
    if b"\x1b]" not in data:
        return data

    palette = _load_omarchy_palette()
    if palette is None:
        return data
    fg, bg, ansi = palette

    def reply(m):
        op = m.group(1)
        if op == b"10":
            r, g, b = fg
        elif op == b"11":
            r, g, b = bg
        else:
            r, g, b = ansi[int(m.group(2))]
        response = f"\x1b]{op.decode()};rgb:{r:02x}/{g:02x}/{b:02x}\x07"
        try:
            os.write(master_fd, response.encode("ascii"))
        except OSError:
            pass
        return b""

    return _OSC_QUERY_RE.sub(reply, data)


def main():
    args = sys.argv[1:]
    cols, rows = 80, 24
    i = 0
    while i < len(args):
        if args[i] == "--cols":
            cols = int(args[i + 1])
            i += 2
        elif args[i] == "--rows":
            rows = int(args[i + 1])
            i += 2
        elif args[i] == "--":
            i += 1
            break
        else:
            break
    cmd = args[i:]
    if not cmd:
        sys.exit("ptyrun: no command given")

    master_fd, slave_fd = pty.openpty()
    fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    pid = os.fork()
    if pid == 0:
        os.close(master_fd)
        os.setsid()
        fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 0)
        os.dup2(slave_fd, 0)
        os.dup2(slave_fd, 1)
        os.dup2(slave_fd, 2)
        if slave_fd > 2:
            os.close(slave_fd)
        os.environ["LINECAST_COLOR"] = "truecolor"
        # Quickshell is a GUI process with no TERM of its own, and linecast's
        # theme probe (_query_theme_via_osc) refuses to even try when TERM is
        # empty or "dumb" -- it never gets as far as writing the OSC query we
        # answer below. A real value here just needs to say "I'm a terminal
        # that understands standard sequences"; the actual escape handling is
        # all on our side (TermCanvas.qml), not a real xterm.
        os.environ.setdefault("TERM", "xterm-256color")
        try:
            os.execvp(cmd[0], cmd)
        except OSError:
            os._exit(127)

    os.close(slave_fd)

    def handle_term(signum, frame):
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_term)
    signal.signal(signal.SIGHUP, handle_term)

    try:
        stdin_open = True
        while True:
            watch = [master_fd] + ([0] if stdin_open else [])
            rlist, _, _ = select.select(watch, [], [])

            if 0 in rlist:
                try:
                    data = os.read(0, 4096)
                except OSError:
                    data = b""
                if data:
                    try:
                        os.write(master_fd, data)
                    except OSError:
                        pass
                else:
                    stdin_open = False

            if master_fd in rlist:
                try:
                    data = os.read(master_fd, 4096)
                except OSError:
                    break
                if not data:
                    break
                data = _answer_osc_queries(data, master_fd)
                if not data:
                    continue
                try:
                    os.write(1, data)
                except OSError:
                    break
    finally:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass


if __name__ == "__main__":
    main()
