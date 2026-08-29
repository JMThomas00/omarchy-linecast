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
  moduleName: "gh0st.linecast"

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

  function refreshWeather() {
    if (!weatherProc.running) weatherProc.running = true
  }

  Process {
    id: weatherProc
    command: ["bash", "-lc", "linecast weather --json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.weatherData = JSON.parse(text || "{}")
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

  Component.onCompleted: root.refreshWeather()

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
  readonly property string frameMarker: "[H"
  property string activeTab: "radar"

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

  function showTab(tabId) {
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
  function keyToBytes(event) {
    switch (event.key) {
      case Qt.Key_Up: return "[A"
      case Qt.Key_Down: return "[B"
      case Qt.Key_Right: return "[C"
      case Qt.Key_Left: return "[D"
      case Qt.Key_Return:
      case Qt.Key_Enter: return "\r"
      case Qt.Key_Backspace: return ""
      case Qt.Key_Tab: return "\t"
      case Qt.Key_PageUp: return "[5~"
      case Qt.Key_PageDown: return "[6~"
      case Qt.Key_Home: return "[H"
      case Qt.Key_End: return "[F"
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
      property var lines: []
      property bool haveFrame: false
      property string buf: ""       // last fully-received frame, ready to paint
      property string pending: ""   // frame currently being assembled
      property bool dirty: false
      property real lastByteMs: 0   // 0 means "nothing pending to settle"

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
          var first = procInstance.pending.indexOf(root.frameMarker)
          if (first === -1) return
          if (first > 0) procInstance.pending = procInstance.pending.slice(first)
          var second = procInstance.pending.indexOf(root.frameMarker, 1)
          if (second !== -1) {
            procInstance.buf = procInstance.pending.slice(0, second)
            procInstance.pending = procInstance.pending.slice(second)
            procInstance.dirty = true
            procInstance.lastByteMs = 0 // already promoted via a clean cut this round
          } else {
            procInstance.lastByteMs = Date.now() // no second marker yet -- idle-settle fallback below
          }
        }
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
        if (proc.lastByteMs > 0 && proc.pending.length > 0 && (now - proc.lastByteMs) >= 50) {
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
    if (root.tabProcs[tabId]) return
    var proc = liveProcComponent.createObject(root, {})
    proc.command = ["python3", root.ptyRunPath,
      "--cols", String(root.termCols), "--rows", String(root.termRows),
      "--", "linecast", tabId, "--live", "--icons", "plain"]
    proc.running = true
    var updated = Object.assign({}, root.tabProcs)
    updated[tabId] = proc
    root.tabProcs = updated // reassign (not mutate) so bindings on tabProcs re-evaluate
  }

  function stopTab(tabId) {
    var proc = root.tabProcs[tabId]
    if (!proc) return
    proc.running = false
    proc.destroy()
    var updated = Object.assign({}, root.tabProcs)
    delete updated[tabId]
    root.tabProcs = updated
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
    target: "gh0st.linecast"

    function open(): void { root.openPanel() }
    function close(): void { root.closePanel() }
    function toggle(): void { root.togglePanel() }
    function selectTab(tab: string): void { root.showTab(tab) }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    centerOnBar: true
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
