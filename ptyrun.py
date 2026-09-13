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
# verified against the pinned install -- see resolve_verified_linecast() --
# rather than trusted off a bare PATH lookup plus a self-reported --version
# string, which any executable named `linecast` earlier on PATH could fake.
# Both paths also relay the child's output through a byte-capped producer
# loop of our own instead of handing Quickshell a raw pipe straight to the
# child, so an unbounded/adversarial stream never reaches Quickshell's own
# QML-side buffering (SplitParser, StdioCollector) before a limit applies --
# see _RelayLimitExceeded and its two callers below.
import ast
import base64
import ctypes
import ctypes.util
import fcntl
import hashlib
import importlib.metadata as importlib_metadata
import json
import os
import pty
import re
import select
import shutil
import signal
import stat
import struct
import sys
import termios
import time

# ---- Backend identity verification -----------------------------------
#
# What "verified" means, and why it changed:
#
# An earlier version of this check re-hashed every file the installed
# distribution claims to have (via importlib.metadata) against that same
# distribution's own RECORD -- but RECORD is written by whatever installed
# the package, at install time. An unpinned `uv tool install linecast` or
# `pipx install linecast` (both of which this plugin's own README used to
# document as equivalent alternatives) can write a self-consistent RECORD
# for a *different* linecast 2.2.0 artifact than the one this plugin was
# actually reviewed against -- same declared version, same internally
# consistent hashes, different bytes. Trusting RECORD as the hash source
# verifies "this install is internally consistent," not "this install is
# the reviewed one."
#
# EXPECTED_DIST is not from the installed environment. It's read from
# linecast-2.2.0.manifest.json, generated once (see that file's header)
# directly from the official linecast 2.2.0 wheel published to PyPI --
# the exact artifact whose sha256 is pinned in requirements-linecast.txt
# and that `pip install --require-hashes` verifies at install time. Every
# hash resolve_verified_linecast() compares against below comes from that
# committed manifest, never from the installed distribution's own RECORD.
EXPECTED_DIST = "linecast"
_MANIFEST_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "linecast-2.2.0.manifest.json"
)

# Individual installed file read during verification, capped so a planted
# oversized file can't make verification itself read something unbounded
# into memory. The manifest's own files are all well under this (the
# largest packaged data file is under 2MB; this leaves headroom without
# being unbounded).
_MAX_VERIFY_FILE_BYTES = 8 * 1024 * 1024
# The generated console-script launcher this plugin actually execs is a
# handful of lines; anything claiming to be one but this large is already
# not the installer-generated boilerplate _verify_launcher_script expects.
_MAX_LAUNCHER_SCRIPT_BYTES = 8192

_manifest_cache = None


def _load_manifest():
    """Load and cache the committed trust-root manifest. Failure here
    (missing file, malformed JSON, missing required keys) must be a hard
    verification failure, not a fallback to some other trust source --
    there is no other trust source."""
    global _manifest_cache
    if _manifest_cache is not None:
        return _manifest_cache
    with open(_MANIFEST_PATH, "r", encoding="utf-8") as fp:
        manifest = json.load(fp)
    for key in ("version", "files", "entry_point"):
        if key not in manifest:
            raise ValueError(f"manifest missing required key: {key}")
    ep = manifest["entry_point"]
    for key in ("module", "attr"):
        if key not in ep:
            raise ValueError(f"manifest entry_point missing required key: {key}")
    _manifest_cache = manifest
    return manifest


def _hash_matches(expected_b64, data):
    """Compare `data` against a manifest-recorded hash. The manifest
    stores sha256 as urlsafe-base64 (no padding), the same encoding
    PEP 376/427 RECORD files use, since it was generated directly from
    the reviewed wheel's own RECORD (see linecast-2.2.0.manifest.json)."""
    digest = hashlib.sha256(data).digest()
    computed = base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")
    return computed == expected_b64


def _verify_launcher_script(source_text, module, attr):
    """The installed distribution's own files are verified above against
    committed hashes -- but the console-script *launcher* we actually exec
    (e.g. site-packages/../bin/linecast) is never one of those files. It's
    generated fresh by whatever installed the package (pip/uv/pipx each use
    a slightly different template), embedding that install's own interpreter
    path in its shebang, so no fixed hash for it can be portable across
    installs the way the manifest's package-file hashes are.

    Instead of pinning bytes, this pins *behavior*: parse the launcher as
    Python and require its entire body to do nothing but import the exact
    manifest-pinned `module:attr` entry point and call it, optionally with
    the standard argv0-suffix-stripping line installers commonly add. Any
    additional import, call, statement, or definition is a hard failure --
    there is no legitimate reason a generated launcher needs to do more
    than this, and anything that does is not the boilerplate it claims to
    be, whether by tampering or by a template this check doesn't recognize."""

    def is_sys_argv0(node):
        return (
            isinstance(node, ast.Subscript) and isinstance(node.value, ast.Attribute)
            and isinstance(node.value.value, ast.Name) and node.value.value.id == "sys"
            and node.value.attr == "argv"
            and isinstance(node.slice, ast.Constant) and node.slice.value == 0
        )

    # The one literal regex distlib/pip's console-script template actually
    # uses for this line -- pinned exactly (not "any string constant")
    # because a regex's *content* can't itself execute code, but pinning it
    # anyway keeps this recognizing one known-benign template rather than
    # silently accepting whatever pattern a tampered/unfamiliar template
    # happens to use.
    _ARGV0_STRIP_RESUB_PATTERN = r"(-script\.pyw|\.exe)?$"

    def is_argv0_strip_resub(node):
        # sys.argv[0] = re.sub(r'(-script\.pyw|\.exe)?$', '', sys.argv[0])
        #
        # Every one of re.sub's three arguments is checked below to be
        # exactly this literal shape -- fixed pattern string, empty literal
        # replacement, sys.argv[0] as the subject -- with no keywords and
        # nothing else accepted positionally. An earlier version of this
        # check only confirmed the *call target* was `re.sub` without ever
        # looking at what was passed to it, so a tampered launcher could
        # smuggle a side-effecting expression (e.g.
        # `__import__("os").system(...)`) in as one of those arguments:
        # Python evaluates call arguments eagerly, so that expression would
        # run the moment the launcher executes regardless of what re.sub
        # itself ends up doing with the result. (Reported directly against
        # this exact function -- see
        # omacom/omarchy-plugin-marketplace#3421.)
        if not (
            isinstance(node, ast.Assign) and len(node.targets) == 1
            and is_sys_argv0(node.targets[0])
            and isinstance(node.value, ast.Call)
            and isinstance(node.value.func, ast.Attribute)
            and isinstance(node.value.func.value, ast.Name)
            and node.value.func.value.id == "re" and node.value.func.attr == "sub"
            and not node.value.keywords
        ):
            return False
        args = node.value.args
        if len(args) != 3:
            return False
        pattern, repl, subject = args
        return (
            isinstance(pattern, ast.Constant) and pattern.value == _ARGV0_STRIP_RESUB_PATTERN
            and isinstance(repl, ast.Constant) and repl.value == ""
            and is_sys_argv0(subject)
        )

    def is_argv0_strip_ifchain(node):
        # if sys.argv[0].endswith("-script.pyw"):
        #     sys.argv[0] = sys.argv[0][:-11]
        # elif sys.argv[0].endswith(".exe"):
        #     sys.argv[0] = sys.argv[0][:-4]
        # (any number of elif branches, each stripping exactly len(suffix)
        # characters off the end for whichever literal suffix it tested)
        if not isinstance(node, ast.If):
            return False
        test = node.test
        if not (isinstance(test, ast.Call) and isinstance(test.func, ast.Attribute)
                and test.func.attr == "endswith" and is_sys_argv0(test.func.value)
                and len(test.args) == 1 and isinstance(test.args[0], ast.Constant)
                and isinstance(test.args[0].value, str) and not test.keywords):
            return False
        suffix_len = len(test.args[0].value)
        if len(node.body) != 1:
            return False
        assign = node.body[0]
        if not (isinstance(assign, ast.Assign) and len(assign.targets) == 1
                and is_sys_argv0(assign.targets[0])
                and isinstance(assign.value, ast.Subscript)
                and is_sys_argv0(assign.value.value)):
            return False
        sl = assign.value.slice
        if not (isinstance(sl, ast.Slice) and sl.lower is None and sl.step is None
                and isinstance(sl.upper, ast.UnaryOp) and isinstance(sl.upper.op, ast.USub)
                and isinstance(sl.upper.operand, ast.Constant)
                and sl.upper.operand.value == suffix_len):
            return False
        if not node.orelse:
            return True
        if len(node.orelse) == 1:
            return is_argv0_strip_ifchain(node.orelse[0])
        return False

    try:
        tree = ast.parse(source_text)
    except SyntaxError as e:
        return False, f"launcher script is not valid Python: {e}"

    body = list(tree.body)
    # An optional module docstring is harmless and common; skip at most one.
    if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant) \
            and isinstance(body[0].value.value, str):
        body = body[1:]

    imported_names = {}  # local name -> "module" or "module.attr" it refers to
    saw_entry_import = False
    remaining = []
    for node in body:
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name not in ("sys", "re") or alias.asname is not None:
                    return False, f"launcher has unexpected import: {alias.name}"
                imported_names[alias.asname or alias.name] = alias.name
        elif isinstance(node, ast.ImportFrom):
            if node.module != module or node.level:
                return False, f"launcher imports from unexpected module: {node.module}"
            if len(node.names) != 1 or node.names[0].name != attr or node.names[0].asname is not None:
                return False, "launcher entry-point import does not match manifest exactly"
            saw_entry_import = True
        else:
            remaining.append(node)

    if not saw_entry_import:
        return False, f"launcher never imports the pinned entry point {module}:{attr}"
    if "sys" not in imported_names.values():
        return False, "launcher never imports sys"

    if len(remaining) != 1 or not isinstance(remaining[0], ast.If):
        return False, "launcher body is not exactly one top-level if-guard"
    guard = remaining[0]
    test = guard.test
    if not (isinstance(test, ast.Compare) and isinstance(test.left, ast.Name)
            and test.left.id == "__name__" and len(test.ops) == 1
            and isinstance(test.ops[0], ast.Eq) and len(test.comparators) == 1
            and isinstance(test.comparators[0], ast.Constant)
            and test.comparators[0].value == "__main__"):
        return False, "launcher's if-guard is not `if __name__ == \"__main__\":`"
    if guard.orelse:
        return False, "launcher's if-guard has an else clause"

    stmts = list(guard.body)
    if not stmts:
        return False, "launcher's if-guard body is empty"

    # Optional, well-known argv0 suffix-stripping installers commonly add,
    # in either of two forms actually observed from different installers'
    # templates (pip/distlib's single re.sub call vs. uv's if/elif chain --
    # confirmed directly against this machine's `uv tool install` output).
    # Neither form does anything beyond trimming a known packaging-specific
    # suffix off sys.argv[0]; nothing else is accepted here.
    if len(stmts) > 1:
        head = stmts[0]
        if not (is_argv0_strip_resub(head) or is_argv0_strip_ifchain(head)):
            return False, "launcher has an unrecognized statement before sys.exit(...)"
        stmts = stmts[1:]

    if len(stmts) != 1:
        return False, "launcher's if-guard has more than just sys.exit(...)"
    final = stmts[0]
    # Every argument slot on both calls here is constrained -- sys.exit's
    # own keywords included, not just its one positional argument -- for
    # the same reason the re.sub fix above needed all three of its
    # arguments checked: an unchecked keyword slot (e.g.
    # `sys.exit(main(), x=__import__("os").system(...))`) is still a place
    # for an arbitrary expression to get evaluated, whether or not sys.exit
    # itself would ever do anything with it.
    ok = (
        isinstance(final, ast.Expr) and isinstance(final.value, ast.Call)
        and isinstance(final.value.func, ast.Attribute)
        and isinstance(final.value.func.value, ast.Name)
        and final.value.func.value.id == "sys" and final.value.func.attr == "exit"
        and len(final.value.args) == 1 and not final.value.keywords
        and isinstance(final.value.args[0], ast.Call)
        and isinstance(final.value.args[0].func, ast.Name)
        and final.value.args[0].func.id == attr
        and not final.value.args[0].args and not final.value.args[0].keywords
    )
    if not ok:
        return False, f"launcher's final statement is not sys.exit({attr}())"
    return True, None


def _verify_launcher_shebang(candidate, venv_root):
    """The launcher's *body* is checked structurally above, but on Linux the
    kernel picks the interpreter that actually runs those bytes from the
    shebang line, before Python ever sees the source -- a shebang pointing
    somewhere else would make the body check moot. Require it to name a
    real, executable `python*` interpreter, and (when the candidate lives
    in a venv) require that interpreter to live inside that same venv.

    That containment check is done against the shebang's literal path, not
    its fully resolved target: a venv's own bin/python is normally itself a
    symlink out to the base interpreter it was created from (confirmed
    directly against this machine's `uv tool install` layout -- .../bin/
    python -> /usr/bin/python), so fully resolving before comparing would
    always place it "outside" the venv and reject every real install. The
    literal shebang path is what the installer actually wrote for this
    venv, which is what we want to confirm; existence/executability is
    still checked against where that path actually leads."""
    try:
        with open(candidate, "rb") as fp:
            first_line = fp.readline(512)
    except OSError as e:
        return False, f"could not read launcher for shebang check: {e}"

    m = re.match(rb"^#!\s*(\S+)\s*$", first_line.rstrip(b"\n"))
    if not m:
        return False, "launcher has no plain `#!<interpreter>` shebang line"
    interp = m.group(1).decode("utf-8", errors="replace")
    if not os.path.isabs(interp):
        return False, f"launcher shebang interpreter is not an absolute path: {interp}"
    target = os.path.realpath(interp)
    if not os.path.isfile(target) or not os.access(target, os.X_OK):
        return False, f"launcher shebang interpreter is not a real executable: {interp}"
    if not os.path.basename(interp).startswith("python") or not os.path.basename(target).startswith("python"):
        return False, f"launcher shebang interpreter is not python: {interp}"
    if venv_root is not None:
        if os.path.commonpath([os.path.normpath(interp), venv_root]) != venv_root:
            return False, f"launcher shebang interpreter is outside its own venv: {interp}"
    return True, None


def _find_pyvenv_root(script_path):
    """Walk upward from a resolved script path looking for the venv it
    belongs to, marked by a pyvenv.cfg at the venv root (one level above
    bin/). Covers `uv tool install` and `pipx install`, which each create
    one isolated venv per tool -- distinct from `pip install --user`'s
    shared user site-packages, which importlib.metadata's default search
    already covers without this. Returns None if no venv is found within a
    few levels (i.e. probably a user-site/system install instead)."""
    d = os.path.dirname(script_path)
    for _ in range(4):
        if os.path.isfile(os.path.join(d, "pyvenv.cfg")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return None


def _venv_site_packages(venv_root):
    lib = os.path.join(venv_root, "lib")
    if os.path.isdir(lib):
        for name in sorted(os.listdir(lib)):
            candidate = os.path.join(lib, name, "site-packages")
            if os.path.isdir(candidate):
                return candidate
    candidate = os.path.join(venv_root, "Lib", "site-packages")  # Windows layout
    return candidate if os.path.isdir(candidate) else None


def resolve_verified_linecast():
    """Resolve the exact `linecast` executable to run and verify its
    identity against the committed manifest (linecast-2.2.0.manifest.json),
    never against anything the installed environment says about itself.
    PATH is used only to find a *candidate* file to inspect -- trust comes
    entirely from the checks below, all of which must pass before anything
    is ever exec'd:

      1. That candidate resolves to a real, on-disk file.
      2. It belongs to a `linecast` distribution discoverable through
         Python's own package database (importlib.metadata) -- checked
         both in the default search path (covers `pip install --user`)
         and, if the candidate lives inside a venv (covers `uv tool
         install` / `pipx install`, which each use one isolated venv per
         tool), in that venv's own site-packages.
      3. That distribution's recorded version matches the manifest's.
      4. Every file installed for it matches the sha256 the manifest
         pinned for that exact relative path, sourced from the officially
         published wheel rather than from this installation's own RECORD
         (see _load_manifest's docstring for why that distinction matters)
         -- and no file exists that the manifest doesn't know about, and no
         manifest file is missing from the installation.
      5. The console-script launcher we're actually about to exec -- which
         isn't one of the distribution's own files, so step 4 can't cover
         it -- is verified separately: its shebang must name a real python
         interpreter inside the same venv (see _verify_launcher_shebang),
         and its body must do nothing but import and call the manifest's
         pinned entry point (see _verify_launcher_script).

    Returns (True, absolute_script_path, version) on success, or
    (False, reason, None) on any failure -- the caller must refuse to run
    linecast at all in that case.
    """
    try:
        manifest = _load_manifest()
    except (OSError, ValueError, json.JSONDecodeError) as e:
        return False, f"could not load trusted backend manifest: {e}", None

    candidate = shutil.which(EXPECTED_DIST)
    if candidate is None:
        return False, "linecast is not installed (see README -> Requirements)", None
    candidate = os.path.realpath(candidate)
    if not os.path.isfile(candidate):
        return False, f"linecast on PATH does not resolve to a real file: {candidate}", None

    venv_root = _find_pyvenv_root(candidate)
    search_path = None
    if venv_root is not None:
        site_packages = _venv_site_packages(venv_root)
        if site_packages is None:
            return False, f"could not locate site-packages under venv {venv_root}", None
        search_path = [site_packages]

    try:
        if search_path is not None:
            dist = next(iter(importlib_metadata.distributions(name=EXPECTED_DIST, path=search_path)))
        else:
            dist = importlib_metadata.distribution(EXPECTED_DIST)
    except (importlib_metadata.PackageNotFoundError, StopIteration):
        return False, (
            f"linecast on PATH ({candidate}) is not backed by a discoverable "
            f"linecast package installation"
        ), None

    if dist.version != manifest["version"]:
        return False, (
            f"installed linecast {dist.version} does not match the pinned "
            f"{manifest['version']} this plugin was reviewed against"
        ), None

    manifest_files = manifest["files"]
    seen_relpaths = set()
    for f in (dist.files or []):
        relpath = str(f)
        # Installers additionally record the console-script launcher itself
        # in RECORD, with a path that walks *upward* out of the
        # distribution's own directory (e.g. "../../../bin/linecast") to
        # reach wherever the venv/user-scripts directory actually is. That
        # launcher is never part of the wheel we generated the manifest
        # from (it's generated fresh at install time, embedding that
        # install's own interpreter path), so it was never a manifest key
        # by design -- it gets its own dedicated verification below
        # (_verify_launcher_shebang / _verify_launcher_script) instead of a
        # fixed hash. Anything else escaping the distribution root this way
        # would be unusual enough to warrant the same "not reviewed"
        # refusal as any other unrecognized file.
        if relpath.startswith("../"):
            continue
        # Installers also write their own bookkeeping into *.dist-info/ at
        # install time -- RECORD (which necessarily can't record its own
        # hash), INSTALLER (which tool did the installing), REQUESTED (an
        # empty marker), direct_url.json (PEP 610 install-source info).
        # These are standard, installer-specific, and never imported or
        # executed, unlike everything else the manifest pins -- skip them
        # the same way as the launcher above rather than failing on content
        # that legitimately differs by installer/environment.
        if os.path.basename(relpath) in ("RECORD", "INSTALLER", "REQUESTED", "direct_url.json") \
                and os.path.dirname(relpath).endswith(".dist-info"):
            continue
        expected_hash = manifest_files.get(relpath)
        if expected_hash is None:
            return False, (
                f"installed linecast has a file outside the reviewed manifest: {relpath}"
            ), None
        try:
            abs_path = dist.locate_file(f)
            path_str = os.fspath(abs_path)
            if os.path.islink(path_str) or not os.path.isfile(path_str):
                return False, f"manifest-pinned file is missing or not a regular file: {path_str}", None
            with open(path_str, "rb") as fp:
                data = fp.read(_MAX_VERIFY_FILE_BYTES)
                if fp.read(1):
                    return False, f"installed file unexpectedly large: {path_str}", None
        except OSError:
            return False, f"could not read installed file for verification: {f}", None

        if not _hash_matches(expected_hash, data):
            return False, f"installed file does not match its manifest-pinned hash: {path_str}", None
        seen_relpaths.add(relpath)

    missing = manifest_files.keys() - seen_relpaths
    if missing:
        return False, f"installation is missing manifest-pinned files: {sorted(missing)[:3]}", None

    shebang_ok, reason = _verify_launcher_shebang(candidate, venv_root)
    if not shebang_ok:
        return False, reason, None

    try:
        with open(candidate, "rb") as fp:
            launcher_bytes = fp.read(_MAX_LAUNCHER_SCRIPT_BYTES)
            if fp.read(1):
                return False, f"launcher script unexpectedly large: {candidate}", None
    except OSError as e:
        return False, f"could not read launcher script: {e}", None

    entry_point = manifest["entry_point"]
    script_ok, reason = _verify_launcher_script(
        launcher_bytes.decode("utf-8", errors="replace"),
        entry_point["module"], entry_point["attr"],
    )
    if not script_ok:
        return False, f"launcher script ({candidate}) failed verification: {reason}", None

    return True, candidate, dist.version


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


# ---- Producer-side output ceiling ---------------------------------------
#
# Quickshell's own line/stream buffering -- QML's SplitParser for the live
# pty tabs, StdioCollector for the one-shot weather fetch -- retains bytes
# internally until it sees a line terminator (SplitParser) or the stream
# closes (StdioCollector), *before* either ever calls back into our QML
# code, which is where BarWidget.qml's own maxPendingBytes/maxJsonBytes
# checks live. A child that never emits a newline (or never closes) can
# make Quickshell buffer an unbounded amount before either of those checks
# ever runs. Kept in sync with BarWidget.qml's maxPendingBytes/maxJsonBytes
# (same 1MB), enforcing the identical ceiling here, on the raw bytes before
# they ever reach Quickshell's stdin pipe, closes that gap regardless of
# what either QML-side check does afterward.
_MAX_RELAY_RUN_BYTES = 1 * 1024 * 1024


class _RelayLimitExceeded(Exception):
    """Raised by _bounded_relay_write once a child's output has gone this
    long without a line terminator -- see _MAX_RELAY_RUN_BYTES."""


def _bounded_relay_write(data, run_bytes):
    """Write `data` to our own stdout, tracking how many bytes have been
    forwarded since the last newline. Returns the updated run length.
    Raises _RelayLimitExceeded *without writing* once forwarding this
    chunk would push that run past the ceiling, so a child that never
    terminates a line (or, for the one-shot no-pty case, never stops
    producing at all) can't make Quickshell's own reader retain more than
    the cap before we've already refused to keep relaying."""
    last_nl = data.rfind(b"\n")
    new_run = (len(data) - last_nl - 1) if last_nl != -1 else (run_bytes + len(data))
    if new_run > _MAX_RELAY_RUN_BYTES:
        raise _RelayLimitExceeded()
    os.write(1, data)
    return new_run


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
        # --json fetch), but we still can't just os.execv() and become it
        # directly: that would hand Quickshell's StdioCollector a pipe
        # straight to the child's stdout with nothing of ours left running
        # to enforce _MAX_RELAY_RUN_BYTES before it retains the lot (see
        # that constant's docstring). Fork with a plain pipe instead, same
        # as the pty path below minus the pty allocation, so this process
        # stays alive to relay through _bounded_relay_write.
        read_fd, write_fd = os.pipe()
        ptyrun_pid = os.getpid()
        pid = os.fork()
        if pid == 0:
            os.close(read_fd)
            os.setsid()
            # PDEATHSIG is cleared across fork(); rearm against ptyrun.py
            # (this child's real parent), with the same already-dead-parent
            # recheck _die_with_parent_checked's docstring explains.
            _die_with_parent_checked(ptyrun_pid)
            os.dup2(write_fd, 1)
            if write_fd > 1:
                os.close(write_fd)
            try:
                os.execv(cmd[0], ["linecast"] + cmd[1:])
            except OSError:
                os._exit(127)

        os.close(write_fd)

        def handle_term(signum, frame):
            _terminate_and_reap(pid)
            sys.exit(0)

        signal.signal(signal.SIGTERM, handle_term)
        signal.signal(signal.SIGHUP, handle_term)

        exit_code = 0
        try:
            run_bytes = 0
            while True:
                try:
                    data = os.read(read_fd, 4096)
                except OSError:
                    break
                if not data:
                    break
                try:
                    run_bytes = _bounded_relay_write(data, run_bytes)
                except _RelayLimitExceeded:
                    sys.stderr.write(
                        "ptyrun: linecast output exceeded the byte ceiling "
                        "without a line terminator; refusing to relay more\n"
                    )
                    exit_code = 1
                    break
        finally:
            os.close(read_fd)
            _terminate_and_reap(pid)
        sys.exit(exit_code)

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
        run_bytes = 0
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
                    run_bytes = _bounded_relay_write(data, run_bytes)
                except _RelayLimitExceeded:
                    sys.stderr.write(
                        "ptyrun: linecast output exceeded the byte ceiling "
                        "without a line terminator; tearing down this tab\n"
                    )
                    break
                except OSError:
                    break
    finally:
        _terminate_and_reap(pid)


if __name__ == "__main__":
    main()
