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

  // Column/row -> pixel, snapped to whole device pixels. Two rects computed
  // as row*lineHeight / (row+1)*lineHeight independently can each round
  // their shared edge a different way (e.g. 53.664 and 53.336), leaving a
  // hairline the rasterizer treats as a real gap -- that's what showed up
  // as faint horizontal seams running across otherwise-solid same-color
  // radar/maps fills. Routing every edge through this one function means
  // row r's bottom and row r+1's top are the literal same rounded number,
  // so adjacent same-color rects always share an exact pixel edge.
  function _colPx(c) { return Math.round(c * charWidth) }
  function _rowPx(r) { return Math.round(r * lineHeight) }

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

    var r, s, row, seg, col, yTop, yBot

    for (r = 0; r < lines.length; r++) {
      row = lines[r]
      yTop = canvas._rowPx(r)
      yBot = canvas._rowPx(r + 1)

      // ---- Backgrounds: merge consecutive same-color cells into one rect.
      col = 0
      var bgRunCol = 0
      var bgRunColor = null
      for (s = 0; s < row.length; s++) {
        seg = row[s]
        if (bgRunColor && canvas._sameColor(seg.bg, bgRunColor)) {
          // still the same run; width picked up when it ends or at flush
        } else {
          if (bgRunColor) {
            ctx.fillStyle = canvas._rgbString(bgRunColor)
            ctx.fillRect(canvas._colPx(bgRunCol), yTop, canvas._colPx(col) - canvas._colPx(bgRunCol), yBot - yTop)
          }
          bgRunCol = col
          bgRunColor = seg.bg || null
        }
        col += seg.text.length
      }
      if (bgRunColor) {
        ctx.fillStyle = canvas._rgbString(bgRunColor)
        ctx.fillRect(canvas._colPx(bgRunCol), yTop, canvas._colPx(col) - canvas._colPx(bgRunCol), yBot - yTop)
      }

      // ---- Foreground text: merge consecutive same-color/weight cells
      //      into one fillText call.
      col = 0
      var runText = ""
      var runCol = 0
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
            canvas._fillRun(ctx, runText, canvas._colPx(runCol), yTop, canvas._colPx(col) - canvas._colPx(runCol))
          }
          runText = seg.text
          runCol = col
          runFg = seg.fg
          runBold = segBold
          haveRun = true
        }
        col += seg.text.length
      }
      if (haveRun && runText.length > 0) {
        ctx.font = (runBold ? "bold " : "") + fontPixelSize + "px " + fontFamily
        ctx.fillStyle = runFg ? canvas._rgbString(runFg) : defaultColor
        canvas._fillRun(ctx, runText, canvas._colPx(runCol), yTop, canvas._colPx(col) - canvas._colPx(runCol))
      }
    }
  }

  // fillText() lays a multi-character string out using the font's own
  // glyph advance widths, which almost never matches charWidth (a fixed
  // pixel-box-divided-by-grid value with no relation to the font's actual
  // metrics at fontPixelSize). Left uncorrected, that mismatch compounds
  // across every character in a run: a long same-colored run (exactly what
  // a state border or coastline draws as) drifts further off its true grid
  // cell the longer the run goes, blurring/smearing braille dot detail
  // that's supposed to line up pixel-for-pixel between neighboring cells.
  // Scaling the whole run horizontally to its exact intended pixel width
  // (targetW, precomputed by the caller from the same _colPx grid the
  // backgrounds use) keeps one draw call per run -- preserving the merge
  // that fixed the earlier lag -- while pinning every run back onto grid.
  function _fillRun(ctx, runText, runX, y, targetW) {
    // A run of plain spaces (the common case for radar/maps cells that only
    // carry a background color, no glyph) paints nothing -- fillText() still
    // costs a font-metrics lookup and a draw call for it regardless. Bailing
    // out here skips that for every such run instead of just the ones that
    // happen to get merged with real glyph runs.
    if (runText.trim().length === 0) return
    // A single character can't drift -- there's nothing for its position to
    // compound against -- so it's not worth paying for measureText() plus
    // the save/scale/restore bracket. Radar/maps frames are mostly exactly
    // this case (many single-cell color changes; see the file-level comment
    // above), so skipping it here matters for repaint cost, not just tidiness.
    if (runText.length <= 1) {
      ctx.fillText(runText, runX, y)
      return
    }
    var measuredW = ctx.measureText(runText).width
    if (measuredW > 0 && Math.abs(measuredW - targetW) > 0.01) {
      ctx.save()
      ctx.translate(runX, y)
      ctx.scale(targetW / measuredW, 1)
      ctx.fillText(runText, 0, 0)
      ctx.restore()
    } else {
      ctx.fillText(runText, runX, y)
    }
  }
}
