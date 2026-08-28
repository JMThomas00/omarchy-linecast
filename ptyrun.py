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
import select
import signal
import struct
import sys
import termios


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
