import QtQuick

// Renders a parsed ANSI grid (see Ansi.js) as if it were a small terminal:
// per-cell background fills behind monospace text, so the half-block color
// tricks linecast's radar/sunshine/maps views rely on actually show up.
//
// Cell size is derived from a fixed pixel box (targetWidth/targetHeight)
// divided by the grid (gridCols/gridRows) that linecast was actually told
// to render at, rather than measured from whatever content happens to
// arrive. Different subcommands don't all fill their requested grid the
// same way (moon draws a smaller disc than radar's edge-to-edge map), so
// sizing off measured content made the box visibly jump size between tabs.
// A fixed cell grid also gives mouse-to-terminal-cell mapping a simple,
// exact conversion (pixel / cellSize), same as a real terminal.
//
// Both passes merge consecutive same-color cells into one draw call
// instead of one per cell: radar/maps frames can carry several hundred
// distinct per-cell colors (a gradient or half-block mosaic, not flat
// fills), and that many draw calls per repaint was the actual source of
// the reported lag — not the Python pty relay, and (measured directly)
// not Ansi.parseAnsi either. An ImageData-based pixel-buffer approach was
// tried for the background pass on the theory that fillRect()'s per-call
// overhead was the cost; it measured far *worse* (QML's JS engine doesn't
// appear to JIT a tight per-pixel write loop the way a browser would), so
// plain merged fillRect() calls are what's actually here.
Canvas {
  id: canvas

  property var lines: []
  property string fontFamily: "monospace"
  property real targetWidth: 400
  property real targetHeight: 280
  property int gridCols: 66
  property int gridRows: 22
  property color defaultColor: "#c9d1d9"

  readonly property real lineHeight: targetHeight / Math.max(1, gridRows)
  readonly property real charWidth: targetWidth / Math.max(1, gridCols)
  readonly property int fontPixelSize: Math.max(6, Math.floor(lineHeight * 0.82))

  implicitWidth: targetWidth
  implicitHeight: targetHeight

  function _sameColor(a, b) {
    if (a === b) return true
    if (!a || !b) return false
    return a.r === b.r && a.g === b.g && a.b === b.b
  }

  function _rgbString(c) {
    return c ? ("rgb(" + c.r + "," + c.g + "," + c.b + ")") : ""
  }

  onLinesChanged: requestPaint()
  onTargetWidthChanged: requestPaint()
  onTargetHeightChanged: requestPaint()
  onAvailableChanged: requestPaint()
  Component.onCompleted: requestPaint()

  onPaint: {
    if (!canvas.available) return
    var ctx = getContext("2d")
    ctx.reset()
    ctx.clearRect(0, 0, Math.max(canvas.width, 4000), Math.max(canvas.height, 4000))
    ctx.textBaseline = "top"

    var r, s, row, seg, x, y, segW

    for (r = 0; r < lines.length; r++) {
      row = lines[r]
      y = r * lineHeight

      // ---- Backgrounds: merge consecutive same-color cells into one rect.
      x = 0
      var bgRunX = 0
      var bgRunW = 0
      var bgRunColor = null
      for (s = 0; s < row.length; s++) {
        seg = row[s]
        segW = seg.text.length * charWidth
        if (bgRunColor && canvas._sameColor(seg.bg, bgRunColor)) {
          bgRunW += segW
        } else {
          if (bgRunColor) {
            ctx.fillStyle = canvas._rgbString(bgRunColor)
            ctx.fillRect(bgRunX, y, bgRunW, lineHeight)
          }
          bgRunX = x
          bgRunW = segW
          bgRunColor = seg.bg || null
        }
        x += segW
      }
      if (bgRunColor) {
        ctx.fillStyle = canvas._rgbString(bgRunColor)
        ctx.fillRect(bgRunX, y, bgRunW, lineHeight)
      }

      // ---- Foreground text: merge consecutive same-color/weight cells
      //      into one fillText call.
      x = 0
      var runText = ""
      var runX = 0
      var runFg = null
      var runBold = false
      var haveRun = false
      for (s = 0; s < row.length; s++) {
        seg = row[s]
        var segBold = !!seg.bold
        if (haveRun && canvas._sameColor(seg.fg, runFg) && segBold === runBold) {
          runText += seg.text
        } else {
          if (haveRun && runText.length > 0) {
            ctx.font = (runBold ? "bold " : "") + fontPixelSize + "px " + fontFamily
            ctx.fillStyle = runFg ? canvas._rgbString(runFg) : defaultColor
            ctx.fillText(runText, runX, y)
          }
          runText = seg.text
          runX = x
          runFg = seg.fg
          runBold = segBold
          haveRun = true
        }
        x += seg.text.length * charWidth
      }
      if (haveRun && runText.length > 0) {
        ctx.font = (runBold ? "bold " : "") + fontPixelSize + "px " + fontFamily
        ctx.fillStyle = runFg ? canvas._rgbString(runFg) : defaultColor
        ctx.fillText(runText, runX, y)
      }
    }
  }
}
