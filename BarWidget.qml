import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Ansi.js" as Ansi

// Companion to omarchy.weather, backed by the `linecast` CLI
// (https://github.com/ashuttl/linecast). The bar pill shows the current
// temperature; clicking it opens a popup with a weather hero card (mirroring
// the native weather widget) plus six tabs — Weather, Radar, Sunshine, Moon,
// Tides, Maps — each rendering that linecast subcommand's own `--live`
// terminal output (captured with LINECAST_COLOR=truecolor over a real pty
// and replayed frame-by-frame onto a small canvas terminal) rather than
// reimplementing each view from scratch — radar's animation included.
BarWidget {
  id: root
  moduleName: "jmthomas00.linecast"

  readonly property var tabs: [
    { id: "weather", label: "Weather" },
    { id: "radar", label: "Radar" },
    { id: "sunshine", label: "Sunshine" },
    { id: "moon", label: "Moon" },
    { id: "tides", label: "Tides" },
    { id: "maps", label: "Maps" }
  ]
  // Higher than linecast's own terminal defaults on purpose: this grid is
  // rendered into a fixed-size box regardless of the host display, so more
  // columns/rows means linecast actually rasterizes finer detail into that
  // space (real data, not just smaller stretched blocks) — most visible on
  // a lower pixel-density display where each cell would otherwise cover a
  // large, flat-colored area.
  readonly property int termCols: 88
  readonly property int termRows: 30
  readonly property int tabContentMargin: 16

  // ---- Hero weather data (also drives the bar pill) ----
  property var weatherData: null
  readonly property var current: weatherData ? weatherData.current : null
  readonly property var todayInfo: weatherData ? weatherData.today : null
  readonly property string tempUnit: weatherData && weatherData.units ? weatherData.units.temperature : "°"
  readonly property string windUnit: weatherData && weatherData.units ? weatherData.units.wind : "mph"
  readonly property string pillText: current ? ((current.icon || "") + " " + Math.round(current.temperature) + tempUnit) : "—"
  readonly property string heroLocation: {
    if (!weatherData || !weatherData.location) return ""
    return String(weatherData.location).split(",")[0].trim()
  }
  readonly property var forecastDays: {
    var daily = weatherData ? weatherData.daily : null
    if (!daily || daily.length < 2) return []
    return daily.slice(1, 4)
  }

  function dayName(dateString) {
    var d = new Date(dateString + "T12:00:00")
    return isNaN(d.getTime()) ? "" : Qt.formatDate(d, "dddd")
  }

  // A legitimate weather --json payload is a few KB; capping well above
  // that before ever handing text to JSON.parse means a backend that goes
  // wrong (or is impersonated) can't force this widget to parse or retain
  // an unbounded string.
  readonly property int maxJsonBytes: 1048576

  function refreshWeather() {
    if (!root.backendOk) return
    if (!weatherProc.running) weatherProc.running = true
  }

  Process {
    id: weatherProc
    // Routed through ptyrun.py's --no-pty mode (plain argv, no shell, no
    // pty needed for a one-shot call) rather than a bare `linecast` argv0:
    // that resolves and hash-verifies the installed backend the same way
    // the tab processes below do, instead of trusting whatever `linecast`
    // PATH lookup happens to find. See ptyrun.py's resolve_verified_linecast().
    command: ["python3", root.ptyRunPath, "--no-pty", "--", "linecast", "weather", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = text || ""
        if (t.length > root.maxJsonBytes) return // oversized/malformed -- keep last-good data
        try {
          root.weatherData = JSON.parse(t || "{}")
        } catch (e) {
          // keep last-good data visible
        }
      }
    }
  }

  Timer {
    interval: 900000 // 15 min
    running: true
    repeat: true
    onTriggered: root.refreshWeather()
  }

  // The backend `linecast` CLI is an independently installed dependency
  // (see README's Requirements/Security sections). Rather than trusting a
  // bare PATH lookup plus whatever version string the resolved executable
  // prints (spoofable by any script named `linecast` earlier on PATH),
  // every actual spawn is resolved and hash-verified by ptyrun.py against
  // the pinned, reviewed release -- see resolve_verified_linecast() there.
  // This check is the UI-facing mirror of that: run once at startup so the
  // panel can show a clear, hard-blocked reason instead of silently never
  // loading, and gate refreshWeather()/ensureTabLive() on it so we don't
  // bother spawning processes ptyrun.py would refuse anyway. It is not the
  // security boundary itself -- ptyrun.py re-verifies on every single
  // spawn regardless of this cached flag, so a stale "OK" here can't let
  // anything unverified actually run.
  property bool backendChecked: false
  property bool backendOk: false
  property string backendVersion: ""
  property string backendBlockReason: ""
  readonly property string linecastVersionWarning: {
    if (!backendChecked || backendOk) return ""
    return "⚠ linecast backend verification failed: " + backendBlockReason +
      ". This plugin will not run until this is fixed — see README → Security."
  }

  Process {
    id: linecastVerifyProc
    command: ["python3", root.ptyRunPath, "--verify-only"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = (text || "").trim()
        root.backendChecked = true
        if (t.indexOf("OK ") === 0) {
          root.backendOk = true
          root.backendVersion = t.slice(3)
          root.refreshWeather()
        } else {
          root.backendOk = false
          root.backendBlockReason = t.indexOf("FAIL ") === 0 ? t.slice(5) : "verification check failed"
        }
      }
    }
  }

  Component.onCompleted: {
    linecastVerifyProc.running = true
  }

  // ---- Tab data: linecast's own `--live` view, streamed frame-by-frame.
  //
  // `--live` refuses to run without a real tty (it needs cbreak mode for
  // keyboard input), so ptyrun.py allocates and sizes a pty itself and execs
  // linecast attached to it (see that file -- `script` was tried first but
  // assumes it has a controlling terminal of its own to relay through, which
  // isn't true when spawned headless with no tty anywhere in the session, as
  // Quickshell does; it silently produced nothing).
  //
  // Every redraw is a full clear-and-repaint, marked by a cursor-home
  // escape (frameMarker below) -- never an in-place partial update. That's
  // what makes radar animate: swap in whatever's been drawn since the last
  // one, same as swapping a static --print snapshot, just continuously
  // instead of once. The exact boundary bytes around it vary between runs
  // (cursor-home immediately followed by erase-screen in one capture,
  // erase-screen/resets then cursor-home in another) but cursor-home alone
  // reliably appears exactly once per frame in both, and any trailing
  // erase/reset codes left dangling are harmless no-ops to Ansi.parseAnsi.
  readonly property string frameMarker: root._esc + "[H"
  property string activeTab: "radar"

  // A real frame at termCols x termRows with truecolor SGR runs before
  // nearly every cell is at most tens of KB. This is a producer/framer
  // byte ceiling, not a content-size guess: if a tab's pty output never
  // delivers a second frameMarker (or a 50ms idle gap) long enough for
  // `pending` to cross this, something is wrong with the stream, and
  // holding it in an ever-growing QML string is the actual risk -- so the
  // proc is killed outright rather than left accumulating.
  readonly property int maxPendingBytes: 1048576

  // Every tab gets its own `--live` process, started once when the panel
  // opens and kept running for as long as it stays open, rather than being
  // killed and respawned on every click. Switching tabs is then just
  // changing which one's already-live output is shown -- instant, no
  // process spawn, no waiting on linecast's own startup/data-fetch time --
  // and a tab you haven't looked at in a while is still current (it kept
  // redrawing in the background) instead of a stale snapshot from whenever
  // you last visited it. Keyed by tabId; see ensureTabLive/stopTab/
  // stopAllTabs below. Six concurrent lightweight CLI processes only while
  // the popup is actually open is a reasonable trade for that.
  property var tabProcs: ({})

  function activeProc() {
    return root.tabProcs[root.activeTab] || null
  }
  readonly property var activeLines: {
    var p = root.tabProcs[root.activeTab]
    return p ? p.lines : []
  }
  readonly property bool haveFrame: {
    var p = root.tabProcs[root.activeTab]
    return !!p && p.haveFrame
  }
  readonly property bool activeTabLoading: {
    var p = root.tabProcs[root.activeTab]
    return !!p && p.running && !p.haveFrame
  }

  // The only place `tabId` should ever be allowed to originate from outside
  // this file's own hardcoded `tabs` list -- the IpcHandler's selectTab()
  // below hands it whatever string an external `qs ipc call` invocation
  // passes, unvalidated. Without this, that string flowed straight through
  // showTab() -> ensureTabLive() into the `linecast` argv, so an
  // option-looking value (anything starting with "-") could land in argv
  // ahead of the fixed "--live" flag instead of being rejected outright.
  function isValidTab(tabId) {
    for (var i = 0; i < root.tabs.length; i++) {
      if (root.tabs[i].id === tabId) return true
    }
    return false
  }

  function showTab(tabId) {
    if (!root.isValidTab(tabId)) return
    root.activeTab = tabId
    root.ensureTabLive(tabId)
  }

  function refreshActiveTab() {
    root.stopTab(root.activeTab)
    root.ensureTabLive(root.activeTab)
  }

  // Translates a key press into the bytes a real terminal would have sent,
  // so radar's theme/layer toggles and maps' pan keys work as if this were
  // an actual terminal. Escape is deliberately excluded -- it stays free to
  // bubble up and close the panel instead of being swallowed here.
  //
  // Every CSI sequence below needs the literal ESC (0x1b) byte first --
  // linecast's own reader (_read_key in _live.py) only enters
  // escape-sequence parsing when the very first byte it reads is ESC;
  // anything else is treated as a plain, unbound keystroke. Confirmed
  // directly: the bare "[C" this used to return had no effect at all on a
  // live radar process, while the correctly-escaped sequence paused
  // auto-play and scrubbed time exactly as arrow keys are supposed to --
  // so arrow keys, Page Up/Down, Home, and End were all silently inert.
  readonly property string _esc: String.fromCharCode(27)

  function keyToBytes(event) {
    switch (event.key) {
      case Qt.Key_Up: return root._esc + "[A"
      case Qt.Key_Down: return root._esc + "[B"
      case Qt.Key_Right: return root._esc + "[C"
      case Qt.Key_Left: return root._esc + "[D"
      case Qt.Key_Return:
      case Qt.Key_Enter: return "\r"
      // DEL (0x7f) -- already correct in the raw source (linecast's
      // _read_key treats either 0x7f or 0x08 as backspace), just spelled
      // explicitly: a literal DEL byte in a string literal is invisible
      // in most editors/diffs and tools -- frameMarker above had the same
      // thing with a real ESC byte, now spelled the same explicit way.
      case Qt.Key_Backspace: return String.fromCharCode(127)
      case Qt.Key_Tab: return "\t"
      case Qt.Key_PageUp: return root._esc + "[5~"
      case Qt.Key_PageDown: return root._esc + "[6~"
      case Qt.Key_Home: return root._esc + "[H"
      case Qt.Key_End: return root._esc + "[F"
      case Qt.Key_Escape: return null
      default:
        if (event.text && event.text.length > 0 && event.text.charCodeAt(0) >= 0x20) return event.text
        return null
    }
  }

  // Resolved relative to this QML file rather than hardcoded, so the plugin
  // works wherever it's actually installed (any user's home directory, or a
  // renamed plugin folder) instead of only on the machine it was built on.
  readonly property string ptyRunPath: decodeURIComponent(Qt.resolvedUrl("ptyrun.py").toString().replace(/^file:\/\//, ""))

  Component {
    id: liveProcComponent

    Process {
      id: procInstance
      stdinEnabled: true
      property string tabId: ""
      property var lines: []
      property bool haveFrame: false
      property string buf: ""       // last fully-received frame, ready to paint
      property string pending: ""   // frame currently being assembled
      property bool dirty: false
      property real lastByteMs: 0   // 0 means "nothing pending to settle"
      // Once a tab has cleanly cut a frame on a second marker, it's proven
      // it redraws often enough that a marker cut will always arrive -- the
      // idle-settle fallback below must never fire for it again. Without
      // this, radar/maps (redraw every ~150-200ms) hit a race: linecast's
      // footer line carries no trailing newline, so SplitParser holds it
      // internally, undelivered, until the *next* frame's bytes supply one.
      // If the 40ms render timer's 50ms idle check lands in that ordinary
      // gap -- which it does on a huge fraction of frames, since 50ms is
      // well under radar's own redraw interval -- it promotes `pending`
      // one line short (footer missing, still stuck inside SplitParser),
      // and then the footer arrives moments later stapled onto the *next*
      // frame's marker, where the `first > 0` trim discards it as
      // stale-prefix garbage. That's what was making the footer/scrubber
      // bar flicker in and out during zoom (confirmed directly: captured
      // the exact promoted `buf` mid-bug, off by exactly one trailing line,
      // every time). A view that only ever idle-settles (weather, moon,
      // tides, sunshine, maps) never sets this, so their fallback is
      // untouched.
      property bool sawSecondMarker: false

      stdout: SplitParser {
        // Only the buffer is updated here — parsing + repainting happens on
        // renderTimer's own schedule below, not once per line. During
        // interaction (drag-panning maps, radar's fast animation) lines can
        // arrive dozens of times a second; reparsing the whole frame and
        // repainting the canvas that often was the actual source of the
        // reported lag, not the pty relay. Capping the render rate here
        // decouples "how often lines arrive" from "how often we do the
        // expensive part."
        //
        // Two ways a frame gets promoted, not one: if a *second* marker
        // shows up, the first frame is done -- cut precisely there, same as
        // the original fix. That's the common case: radar actually redraws
        // every ~150-200ms while scrubbing its animated playhead (measured
        // directly), not the ~2s this comment used to assume, so a second
        // marker is normally already here well before renderTimer's 50ms
        // idle-settle check below would ever fire. Relying on idle-only
        // measured as a real bug: if two full frames land inside the same
        // ~50ms window (exactly what radar's fast redraws do), nothing cuts
        // between them and they get promoted concatenated into one
        // oversized, garbled `buf`. The idle-settle fallback exists purely
        // for a view that may never send a second marker within any
        // reasonable time (weather, moon, tides, sunshine, maps all redraw
        // on the order of a minute or more) -- no marker cut is possible
        // there since there's nothing to cut against.
        onRead: function(line) {
          procInstance.pending += line + "\n"
          if (procInstance.pending.length > root.maxPendingBytes) {
            // No frame boundary has shown up across an unreasonable amount
            // of output -- stop trusting this stream rather than keep
            // growing an unbounded buffer. stopTab()/onExited below tear
            // it down properly; ensureTabLive() will spawn a fresh one the
            // next time this tab is shown or refreshed.
            root.stopTab(procInstance.tabId)
            return
          }
          var first = procInstance.pending.indexOf(root.frameMarker)
          if (first === -1) return
          if (first > 0) procInstance.pending = procInstance.pending.slice(first)
          var second = procInstance.pending.indexOf(root.frameMarker, 1)
          if (second !== -1) {
            procInstance.buf = procInstance.pending.slice(0, second)
            procInstance.pending = procInstance.pending.slice(second)
            procInstance.dirty = true
            procInstance.lastByteMs = 0 // already promoted via a clean cut this round
            procInstance.sawSecondMarker = true
          } else if (!procInstance.sawSecondMarker) {
            procInstance.lastByteMs = Date.now() // no second marker yet -- idle-settle fallback below
          }
        }
      }

      onExited: function(exitCode, exitStatus) {
        // Only destroy once the process has actually confirmed exit --
        // ptyrun.py's own teardown waits up to ~2s for the whole process
        // group to die before escalating to SIGKILL, so destroying this
        // object any earlier (the old stopTab() did so synchronously)
        // would tear down its buffers while that cleanup was still in
        // flight underneath it. Also covers an unrequested exit (crash,
        // or the oversize-buffer kill above) by making sure the tab is no
        // longer referenced from tabProcs either way, so ensureTabLive()
        // is free to start a fresh one next time this tab is shown.
        if (root.tabProcs[procInstance.tabId] === procInstance) root._dropTabProc(procInstance.tabId)
        procInstance.destroy()
      }
    }
  }

  // Parses + repaints every live tab on a fixed schedule rather than once
  // per line arrival (see the SplitParser comment above for why), and does
  // so for *every* running tab each tick, not just the active one -- that's
  // what keeps background tabs current while you're looking at a different
  // one, instead of freezing them the moment they lose focus.
  //
  // A frame is promoted from `pending` to `buf` once linecast pauses
  // writing for ~50ms, not once a *second* frame starts (an earlier version
  // of this fix). That worked for radar -- redraws every ~2s, so the next
  // frame's marker arrives almost immediately -- but meant a slow view
  // (weather, moon, tides, sunshine, maps) that only redraws once a minute
  // or more never showed anything at all until its *second* redraw
  // happened. Every view's own frame transmission, however rarely it
  // recurs, still completes in milliseconds over the local pty (confirmed
  // directly: moon emits exactly one frameMarker in 8 full seconds of
  // --live output), so a short quiet-period check catches "this frame is
  // done" correctly regardless of how often that frame recurs, while still
  // never painting a frame mid-write the way plain per-line promotion did.
  Timer {
    interval: 40 // ~25fps cap; plenty for a small preview pane
    running: true
    repeat: true
    onTriggered: {
      var now = Date.now()
      for (var tabId in root.tabProcs) {
        var proc = root.tabProcs[tabId]
        if (!proc) continue
        if (!proc.sawSecondMarker && proc.lastByteMs > 0 && proc.pending.length > 0 && (now - proc.lastByteMs) >= 50) {
          proc.buf = proc.pending
          proc.pending = ""
          proc.dirty = true
          proc.lastByteMs = 0
        }
        if (!proc.dirty) continue
        proc.dirty = false
        var parsed = Ansi.parseAnsi(proc.buf)
        if (parsed.length === 0 || (parsed.length === 1 && parsed[0].length === 0)) continue
        proc.lines = parsed
        proc.haveFrame = true
      }
    }
  }

  // No-op if tabId is already running -- safe to call on every showTab().
  function ensureTabLive(tabId) {
    if (!root.backendOk) return
    if (!root.isValidTab(tabId)) return
    if (root.tabProcs[tabId]) return
    var proc = liveProcComponent.createObject(root, { tabId: tabId })
    proc.command = ["python3", root.ptyRunPath,
      "--cols", String(root.termCols), "--rows", String(root.termRows),
      "--", "linecast", tabId, "--live", "--icons", "plain"]
    proc.running = true
    var updated = Object.assign({}, root.tabProcs)
    updated[tabId] = proc
    root.tabProcs = updated // reassign (not mutate) so bindings on tabProcs re-evaluate
  }

  // Removes tabId from the map bindings read from, without touching the
  // Process object itself -- see liveProcComponent's onExited, which is
  // what actually destroys it once exit is confirmed.
  function _dropTabProc(tabId) {
    if (!(tabId in root.tabProcs)) return
    var updated = Object.assign({}, root.tabProcs)
    delete updated[tabId]
    root.tabProcs = updated
  }

  function stopTab(tabId) {
    var proc = root.tabProcs[tabId]
    if (!proc) return
    root._dropTabProc(tabId) // stop treating it as this tab's live process immediately...
    proc.running = false     // ...but let onExited destroy it once ptyrun.py confirms the
                              // whole process group actually terminated, not before.
  }

  function stopAllTabs() {
    for (var tabId in root.tabProcs) root.stopTab(tabId)
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root, direction)
    return false
  }

  function openPanel() {
    panel.open = true
    root.refreshWeather()
    // Start every tab now, not just the active one -- all six are already
    // warm by the time you click over to any of them, not just the ones
    // you happened to visit before. See the tabProcs comment above.
    for (var i = 0; i < root.tabs.length; i++) root.ensureTabLive(root.tabs[i].id)
  }
  function closePanel() {
    panel.open = false
    root.stopAllTabs()
  }
  // Routes through open/closePanel() rather than flipping panel.open
  // directly -- a plain click on the bar button is the normal way this
  // panel opens, so it has to run the same warm-up (weather refresh, all
  // six tabs starting) as the IPC/hotkey open() path, not just show an
  // empty panel that only starts fetching once you click into a tab.
  function togglePanel() {
    if (panel.open) root.closePanel()
    else root.openPanel()
  }

  // Bar-widget contract for hotkey/summon routing (Bar.findPanelWidget wants
  // open/close/opened on the bar-widget root).
  readonly property bool opened: panel.open
  function open() { openPanel() }
  function close() { closePanel() }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.pillText
    fontSize: Style.font.caption
    horizontalMargin: 8
    tooltipText: root.current ? root.current.condition : ""
    onPressed: root.togglePanel()
  }

  IpcHandler {
    target: "jmthomas00.linecast"

    function open(): void { root.openPanel() }
    function close(): void { root.closePanel() }
    function toggle(): void { root.togglePanel() }
    function selectTab(tab: string): void { root.showTab(tab) }
  }

  // Which bar section (left/center/right) this widget's own icon currently
  // sits in — read from shell.json's persisted layout via `bar.layoutConfig`
  // (`{left:[{id},...], center:[...], right:[...]}`), the same source
  // `plugins/bar/widgets/Tray.qml` reads for its own (unrelated) ownership
  // check — there's no `bar.section`/`bar.region` property handed to a
  // widget directly. Reactive: `layoutConfig` itself updates when the user
  // drags an icon to a different section, so this follows without needing
  // a restart.
  function _currentBarSection() {
    var layout = root.bar && root.bar.layoutConfig ? root.bar.layoutConfig : null
    if (!layout) return "center"
    var sections = ["left", "center", "right"]
    for (var i = 0; i < sections.length; i++) {
      var list = layout[sections[i]]
      if (!Array.isArray(list)) continue
      for (var j = 0; j < list.length; j++) {
        if (list[j] && list[j].id === root.moduleName) return sections[i]
      }
    }
    return "center"
  }
  readonly property string barSection: root._currentBarSection()

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    // Mimics the native bar plugins' own left/center/right popup placement
    // convention: a center-section icon centers on the whole screen
    // (`centerOnBar: true`); a left/right-section icon instead centers
    // under its own icon position and lets KeyboardPanel's existing
    // screen-edge clamp (`cardOrigin`) pull it flush to that edge.
    centerOnBar: root.barSection === "center"
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(660))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(660))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.closePanel()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: panelColumn
        width: parent.width
        spacing: Style.space(14)

        // ---- Hero row: icon + temp on the left; location and stats on the right.
        Item {
          width: parent.width
          height: Math.max(heroLeft.height, heroRight.height)

          Row {
            id: heroLeft
            anchors.left: parent.left
            anchors.leftMargin: Style.space(16)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(16)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.current ? (root.current.icon || "—") : "—"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: 64
            }

            Row {
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                id: tempBig
                text: root.current ? String(Math.round(root.current.temperature)) : "—"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: 56
                font.bold: true
              }
              Text {
                text: root.current ? root.tempUnit : ""
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.display
                anchors.top: tempBig.top
                anchors.topMargin: Style.space(10)
              }
            }
          }

          Column {
            id: heroRight
            anchors.right: parent.right
            anchors.rightMargin: Style.space(20)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(12)

            Row {
              visible: root.heroLocation !== ""
              spacing: Style.space(6)
              anchors.right: parent.right

              Text {
                text: "" // nf-fa-map_marker
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                text: root.heroLocation.toUpperCase()
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.letterSpacing: 1
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Row {
              visible: !!root.current
              spacing: Style.space(28)
              anchors.right: parent.right

              Column {
                spacing: Style.space(5)
                Text {
                  text: "FEELS"
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }
                Text {
                  text: root.current ? (Math.round(root.current.feels_like) + root.tempUnit) : ""
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.title
                }
              }
              Column {
                spacing: Style.space(5)
                Text {
                  text: "WIND"
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }
                Text {
                  text: root.current ? (Math.round(root.current.wind_speed) + " " + root.windUnit) : ""
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.title
                }
              }
              Column {
                spacing: Style.space(5)
                Text {
                  text: "HUMID"
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }
                Text {
                  text: root.current ? (root.current.humidity + "%") : ""
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.title
                }
              }
            }
          }
        }

        Text {
          visible: root.linecastVersionWarning !== ""
          text: root.linecastVersionWarning
          width: parent.width
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
          color: root.bar.foreground
          opacity: 0.85
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          visible: !root.current
          text: "Fetching weather…"
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.italic: true
          anchors.horizontalCenter: parent.horizontalCenter
        }

        Rectangle {
          visible: root.forecastDays.length > 0
          width: parent.width
          height: Style.spacing.hairline
          color: root.bar.foreground
          opacity: 0.12
        }

        // ---- 3-day forecast row.
        Item {
          visible: root.forecastDays.length > 0
          width: parent.width
          height: forecastRow.height

          Row {
            id: forecastRow
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(44)

            Repeater {
              model: root.forecastDays

              Row {
                required property var modelData
                spacing: Style.space(10)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.icon || ""
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.display
                }

                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Text {
                    text: root.dayName(modelData.date).toUpperCase()
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                  }

                  Row {
                    spacing: Style.space(6)
                    Text {
                      text: Math.round(modelData.high) + "°"
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                    }
                    Text {
                      text: Math.round(modelData.low) + "°"
                      color: Qt.darker(root.bar.foreground, 1.5)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                    }
                  }
                }
              }
            }
          }
        }

        Rectangle {
          width: parent.width
          height: Style.spacing.hairline
          color: root.bar.foreground
          opacity: 0.12
        }

        // ---- Tab bar.
        Row {
          spacing: Style.space(6)
          anchors.left: parent.left
          anchors.leftMargin: Style.space(16)

          Repeater {
            model: root.tabs

            Rectangle {
              required property var modelData
              readonly property bool active: root.activeTab === modelData.id
              width: tabLabel.implicitWidth + Style.space(20)
              height: tabLabel.implicitHeight + Style.space(10)
              radius: Style.cornerRadius
              color: active ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

              Text {
                id: tabLabel
                anchors.centerIn: parent
                text: modelData.label
                color: parent.active ? Style.hoverStateColor(root.bar.foreground, Color.accent) : Qt.darker(root.bar.foreground, 1.3)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.showTab(modelData.id)
              }
            }
          }
        }

        // ---- Active tab content: linecast's own `--live` output, replayed
        //      onto a small canvas terminal, frame by frame. Keyboard and
        //      mouse are forwarded into the pty (arrow keys/letters as raw
        //      bytes, clicks/drags/wheel as SGR mouse-protocol sequences),
        //      so views with their own interactivity -- radar's theme/layer
        //      toggles, maps' pan and zoom -- actually work, not just play
        //      back like a recording. The canvas is sized to this box
        //      divided evenly by termCols/termRows rather than to whatever
        //      content happens to arrive, so every tab renders at the same
        //      pixel size regardless of how much of its grid a given view
        //      actually draws into (moon's disc vs. radar's edge-to-edge
        //      map) -- and that fixed cell size is what makes the
        //      mouse-pixel-to-terminal-cell math below exact.
        Item {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: Style.space(root.tabContentMargin)
          anchors.rightMargin: Style.space(root.tabContentMargin)
          height: Style.space(280)

          Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius
            color: Color.popups.background
            border.width: Style.spacing.hairline
            border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
          }

          Text {
            visible: root.activeLines.length === 0
            anchors.centerIn: parent
            text: root.activeTabLoading ? "Loading…" : "No data"
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }

          Item {
            id: termArea
            anchors.fill: parent
            anchors.margins: Style.space(8)
            clip: true

            TermCanvas {
              id: termCanvas
              anchors.fill: parent
              lines: root.activeLines
              fontFamily: root.bar.fontFamily
              targetWidth: termArea.width
              targetHeight: termArea.height
              gridCols: root.termCols
              gridRows: root.termRows
              defaultColor: root.bar.foreground
            }

            MouseArea {
              id: termMouse
              anchors.fill: parent
              acceptedButtons: Qt.AllButtons
              hoverEnabled: true

              // Drag-move throttling: a raw pointer-move signal fires far
              // more often than the terminal grid has resolution for, and
              // linecast redraws its whole view on every motion event it
              // receives -- forwarding every pixel-level move multiplies
              // how often the *source* redraws, not just how often we do.
              // renderTimer above already caps how often we reparse/repaint
              // what arrives; this caps how much arrives in the first
              // place. Send at most once per cell moved into, and no more
              // than every 30ms regardless.
              property int lastDragCol: -1
              property int lastDragRow: -1
              property real lastDragMs: 0

              function cellFor(mx, my) {
                return {
                  col: Math.max(1, Math.floor(mx / termCanvas.charWidth) + 1),
                  row: Math.max(1, Math.floor(my / termCanvas.lineHeight) + 1)
                }
              }

              function sendMouse(mx, my, btnCode, release) {
                var proc = root.activeProc()
                if (!proc || !proc.running) return null
                var cell = cellFor(mx, my)
                proc.write("\u001b[<" + btnCode + ";" + cell.col + ";" + cell.row + (release ? "m" : "M"))
                return cell
              }

              onPressed: function(mouse) {
                termMouse.forceActiveFocus()
                var cell = sendMouse(mouse.x, mouse.y, mouse.button === Qt.RightButton ? 2 : (mouse.button === Qt.MiddleButton ? 1 : 0), false)
                if (cell) { lastDragCol = cell.col; lastDragRow = cell.row; lastDragMs = Date.now() }
              }
              onReleased: function(mouse) {
                sendMouse(mouse.x, mouse.y, mouse.button === Qt.RightButton ? 2 : (mouse.button === Qt.MiddleButton ? 1 : 0), true)
              }
              onPositionChanged: function(mouse) {
                if (!pressed) return
                var now = Date.now()
                if (now - lastDragMs < 30) return
                var cell = cellFor(mouse.x, mouse.y)
                if (cell.col === lastDragCol && cell.row === lastDragRow) return
                sendMouse(mouse.x, mouse.y, 32, false)
                lastDragCol = cell.col
                lastDragRow = cell.row
                lastDragMs = now
              }
              onWheel: function(wheel) {
                sendMouse(wheel.x, wheel.y, wheel.angleDelta.y > 0 ? 64 : 65, false)
              }

              Keys.onPressed: function(event) {
                var proc = root.activeProc()
                if (!proc || !proc.running) { event.accepted = false; return }
                var bytes = root.keyToBytes(event)
                if (bytes === null) { event.accepted = false; return }
                proc.write(bytes)
                event.accepted = true
              }
            }
          }

          Rectangle {
            width: refreshLabel.implicitWidth + Style.space(12)
            height: refreshLabel.implicitHeight + Style.space(6)
            radius: Style.cornerRadius
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: Style.space(6)
            color: refreshArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

            Text {
              id: refreshLabel
              anchors.centerIn: parent
              text: "⟳"
              color: Qt.darker(root.bar.foreground, 1.3)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall

              RotationAnimator on rotation {
                running: root.activeTabLoading
                from: 0; to: 360
                duration: 800
                loops: Animation.Infinite
              }
            }

            MouseArea {
              id: refreshArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.refreshActiveTab()
            }
          }
        }
      }
    }
  }
}
