#!/usr/bin/env python3
# Runs a command attached to a real pty, sized to --cols/--rows, and relays
# its output byte-for-byte to our own stdout via raw os.write (no stdio
# buffering to fight). Exists because `script` assumes it has a controlling
# terminal of its own to relay through, which isn't true when spawned
# headless (no tty anywhere in the session) by a process manager like
# Quickshell — it silently produces nothing in that case. This wrapper only
# needs pty/fcntl/termios/importlib.metadata (all stdlib), so it opens and
# sizes the pty itself and never depends on inheriting a terminal.
#
# Also relays our own stdin to the pty, so a caller with a writable pipe to
# our stdin (Quickshell's Process.write()) can forward real keyboard/mouse
# input to the child -- what makes linecast's own interactivity (radar's
# theme/layer toggles, maps' pan and zoom) work instead of just watching a
# recording of it.
#
# Every invocation whose command is `linecast` (the pty path below, and the
# --no-pty path used for the one-shot weather JSON fetch) is resolved and
# hash-verified against the pinned install -- see resolve_verified_linecast()
# -- rather than trusted off a bare PATH lookup plus a self-reported
# --version string, which any executable named `linecast` earlier on PATH
# could fake.
import base64
import ctypes
import ctypes.util
import fcntl
import hashlib
import importlib.metadata as importlib_metadata
import os
import pty
import re
import select
import signal
import stat
import struct
import sys
import sysconfig
import termios
import time

# ---- Backend identity verification -----------------------------------
#
# Keep in sync with requirements-linecast.txt / README.md's Requirements
# section -- this is the one release this plugin has been reviewed against.
EXPECTED_DIST = "linecast"
EXPECTED_VERSION = "2.2.0"

# Individual installed file read during hash verification, capped so a
# planted oversized file can't make verification itself read something
# unbounded into memory.
_MAX_VERIFY_FILE_BYTES = 8 * 1024 * 1024


def _file_hash_ok(filehash, data):
    """Compare `data` against a RECORD-recorded hash. RECORD stores
    sha256 as urlsafe-base64 (no padding) per PEP 376/427, not hex."""
    if filehash is None or filehash.mode != "sha256":
        return None  # nothing recorded for this file -- not itself a failure
    digest = hashlib.sha256(data).digest()
    computed = base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")
    return computed == filehash.value


def resolve_verified_linecast():
    """Resolve the exact `linecast` executable to run and verify its
    installed identity, rather than trusting a bare `linecast` on PATH plus
    whatever version string it prints (a different executable earlier on
    PATH can print anything it likes). Three checks, all of which must pass
    before anything is ever exec'd:

      1. A `linecast` distribution is actually installed, found via pip's
         own package database (importlib.metadata), never via PATH lookup.
      2. Its recorded version is exactly the one this plugin was reviewed
         against.
      3. Every file pip installed for it -- including the console-script
         entry point we're about to exec -- still matches the sha256 hash
         pip itself wrote into RECORD at install time, so a file swapped in
         after installation (accidentally or otherwise) is caught instead
         of silently executed.

    Only a `pip install --user --require-hashes` install (see README) is
    supported -- that's the one layout whose console-script location is
    both deterministic and covered by hash-verified RECORD entries.

    Returns (True, absolute_script_path, version) on success, or
    (False, reason, None) on any failure -- the caller must refuse to run
    linecast at all in that case, never fall back to a PATH lookup.
    """
    try:
        dist = importlib_metadata.distribution(EXPECTED_DIST)
    except importlib_metadata.PackageNotFoundError:
        return False, "linecast is not installed (see README -> Requirements)", None

    if dist.version != EXPECTED_VERSION:
        return False, (
            f"installed linecast {dist.version} does not match the pinned "
            f"{EXPECTED_VERSION} this plugin was reviewed against"
        ), None

    verified_paths = set()
    for f in (dist.files or []):
        try:
            abs_path = dist.locate_file(f)
            path_str = os.fspath(abs_path)
            if os.path.islink(path_str) or not os.path.isfile(path_str):
                continue
            fh = getattr(f, "hash", None)
            if fh is None or fh.mode != "sha256":
                continue
            with open(path_str, "rb") as fp:
                data = fp.read(_MAX_VERIFY_FILE_BYTES)
                if fp.read(1):
                    return False, f"installed file unexpectedly large: {path_str}", None
        except OSError:
            return False, f"could not read installed file for verification: {f}", None

        if not _file_hash_ok(fh, data):
            return False, f"installed file does not match its recorded install-time hash: {path_str}", None
        verified_paths.add(os.path.realpath(path_str))

    scheme = "posix_user" if os.name != "nt" else "nt_user"
    scripts_dir = os.path.realpath(sysconfig.get_path("scripts", scheme))
    script_path = os.path.join(scripts_dir, "linecast")
    if os.path.realpath(script_path) not in verified_paths:
        return False, (
            f"linecast console script not found among hash-verified installed "
            f"files at {script_path} -- only `pip install --user "
            f"--require-hashes -r requirements-linecast.txt` is supported"
        ), None

    return True, script_path, dist.version


# ---- Orphan protection -------------------------------------------------
#
# Quickshell normally shuts us down cooperatively (proc.running = false ->
# SIGTERM -> our handle_term below -> the whole process group killed), but
# that only runs if Quickshell itself exits cleanly. A crash, `kill -9`, or
# a hard shell restart (quickshell kill -p ...) skips all of that, and
# without this, both ptyrun.py and the linecast process it execs are
# reparented to init and run forever -- confirmed directly: restarting the
# Omarchy shell during testing left prior sessions' ptyrun+linecast pairs
# running minutes later, still burning CPU. PR_SET_PDEATHSIG asks the
# kernel to deliver SIGTERM to us the moment our parent thread's process
# exits, for any reason, so orphaning can't happen even on a hard kill.
_PR_SET_PDEATHSIG = 1


def _die_with_parent():
    try:
        libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
        libc.prctl(_PR_SET_PDEATHSIG, signal.SIGTERM, 0, 0, 0)
    except Exception:
        pass


def _die_with_parent_checked(expected_ppid):
    """Arm PDEATHSIG, then immediately recheck. prctl only fires on a
    *future* parent-death event -- if the parent already exited in the
    window between fork()/process start and this call, no such event will
    ever occur and we'd otherwise run forever undetected, reparented to
    init. getppid() no longer matching the pid we expected means exactly
    that already happened; terminate now instead of trusting a signal that
    will never come."""
    _die_with_parent()
    if os.getppid() != expected_ppid:
        os._exit(1)


# ---- Theme-file read (OSC 10/11/4 answers) -----------------------------
#
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
# A themed terminal's answer to a color query is a handful of short lines;
# bounding the read protects against a colors.toml that's grown huge or
# never stops producing bytes.
_MAX_THEME_FILE_BYTES = 65536


def _parse_colors_toml(path):
    # `~/.local/state/omarchy/current` is *meant* to be a symlink -- that's
    # how Omarchy's own theme switcher repoints "the active theme" -- so we
    # don't (and shouldn't) reject symlinks anywhere in the parent chain.
    # What we do guard is the leaf file itself, opened and checked as one
    # atomic, fd-based operation (no separate stat-then-open, which would
    # leave a TOCTOU window for it to be swapped underneath us):
    # O_NOFOLLOW refuses to open it if that exact path is itself a symlink,
    # O_NONBLOCK keeps a FIFO with no writer from hanging this open() rather
    # than a normal file, and the fstat() below confirms what we actually
    # got a descriptor to is a regular file owned by us before reading any
    # of it, with a bounded read on top regardless.
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None

    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return None
        if st.st_uid != os.getuid():
            return None
        if st.st_size > _MAX_THEME_FILE_BYTES:
            return None
        data = b""
        try:
            while len(data) < _MAX_THEME_FILE_BYTES:
                chunk = os.read(fd, _MAX_THEME_FILE_BYTES - len(data))
                if not chunk:
                    break
                data += chunk
        except BlockingIOError:
            pass
    except OSError:
        return None
    finally:
        os.close(fd)

    kv = {}
    for line in data.decode("utf-8", errors="replace").splitlines():
        line = line.strip()
        m = re.match(r'^(\w+)\s*=\s*"([^"]*)"', line)
        if m:
            kv[m.group(1)] = m.group(2)
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


# ---- Process-group teardown ---------------------------------------------
#
# The child below calls os.setsid() right after fork(), which makes it both
# a new session leader and a new process group leader (pgid == pid) -- so
# `pid` here doubles as the process-group id for everything it and its own
# descendants do, unless one of them further detaches on its own.
_TERM_GRACE_SECONDS = 2.0


def _terminate_and_reap(pid):
    """Kill the whole process group, escalating to SIGKILL if it hasn't
    exited within the grace period, then reap it so it never lingers as a
    zombie. Called from both the signal handler and the normal-exit path,
    so every way ptyrun.py stops results in the same bounded cleanup of
    the entire process tree instead of signaling only the one direct child
    PID and hoping its own descendants happen to go down with it."""
    try:
        os.killpg(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    except PermissionError:
        pass

    deadline = time.monotonic() + _TERM_GRACE_SECONDS
    while time.monotonic() < deadline:
        try:
            reaped_pid, _ = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return
        if reaped_pid == pid:
            return
        time.sleep(0.05)

    try:
        os.killpg(pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass


def main():
    args = sys.argv[1:]

    if args[:1] == ["--verify-only"]:
        ok, info, version = resolve_verified_linecast()
        if ok:
            print(f"OK {version}")
            sys.exit(0)
        print(f"FAIL {info}")
        sys.exit(1)

    # Arm PDEATHSIG for ptyrun.py itself now (covers both modes below), and
    # immediately recheck against the parent pid captured before arming --
    # see _die_with_parent_checked's docstring for why the recheck matters.
    quickshell_pid = os.getppid()
    _die_with_parent_checked(quickshell_pid)

    no_pty = False
    cols, rows = 80, 24
    i = 0
    while i < len(args):
        if args[i] == "--cols":
            cols = int(args[i + 1])
            i += 2
        elif args[i] == "--rows":
            rows = int(args[i + 1])
            i += 2
        elif args[i] == "--no-pty":
            no_pty = True
            i += 1
        elif args[i] == "--":
            i += 1
            break
        else:
            break
    cmd = args[i:]
    if not cmd:
        sys.exit("ptyrun: no command given")

    if cmd[0] == "linecast":
        ok, resolved, _version = resolve_verified_linecast()
        if not ok:
            sys.stderr.write(f"ptyrun: refusing to run linecast: {resolved}\n")
            sys.exit(1)
        cmd = [resolved] + cmd[1:]

    if no_pty:
        # No pty needed for a plain one-shot command (e.g. the weather
        # --json fetch): just become it. PDEATHSIG survives execve, and
        # Quickshell's normal SIGTERM-on-stop now lands on the exec'd
        # process directly since it's the same pid.
        try:
            os.execv(cmd[0], ["linecast"] + cmd[1:])
        except OSError:
            sys.exit(127)
        return

    master_fd, slave_fd = pty.openpty()
    fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    ptyrun_pid = os.getpid()
    pid = os.fork()
    if pid == 0:
        os.close(master_fd)
        os.setsid()
        # PDEATHSIG is cleared for the child of a fork(), so the arm above
        # only protects ptyrun.py itself -- rearm here, against ptyrun.py
        # (this child's real parent) rather than Quickshell, with the same
        # already-dead-parent recheck.
        _die_with_parent_checked(ptyrun_pid)
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
            os.execv(cmd[0], ["linecast"] + cmd[1:])
        except OSError:
            os._exit(127)

    os.close(slave_fd)

    def handle_term(signum, frame):
        _terminate_and_reap(pid)
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
        _terminate_and_reap(pid)


if __name__ == "__main__":
    main()
