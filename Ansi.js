// ANSI parser for linecast output captured with LINECAST_COLOR=truecolor.
// Handles any CSI sequence (ESC [ ... <terminator>), not just SGR ('m'):
// live-mode frames also carry erase-line ('K') and, at frame boundaries,
// cursor-home/erase-screen ('H'/'J') — those are consumed silently since a
// full-frame chunk (see BarWidget.qml's frame splitting) never needs to act
// on them, only 'm' (color/bold) actually changes what gets drawn.
//
// fg/bg are kept as plain {r,g,b} objects rather than formatted "rgb(...)"
// strings: TermCanvas's background pass writes straight into a pixel
// buffer and never needs a CSS string at all, and its text pass only
// formats one per run instead of once per parsed segment.
function _colorEq(a, b) {
  if (a === b) return true
  if (!a || !b) return false
  return a.r === b.r && a.g === b.g && a.b === b.b
}

// Known gap: linecast's floating overlays (the theme picker opened with
// 't', and likely others -- warning tooltips, maps' search/route panel)
// position each of their rows with an absolute cursor jump (CSI row;colH),
// not sequential text -- confirmed directly by capturing the raw bytes
// with the picker open. This parser has no notion of a 2D addressable
// grid (it only ever appends to whatever row is currently open, splitting
// on literal '\n'), so a mid-frame row;col jump lands as more text tacked
// onto whatever row is already open rather than at its real position --
// the picker's box currently renders squashed onto the footer row instead
// of as its own box. Properly fixing it means turning this into a real
// cursor-addressable grid (plus handling reverse-video SGR, which the
// picker's selected-row highlight also uses and this parser doesn't
// support either) -- out of scope here since it only affects a secondary
// interactive extra, not the core dashboard views, all of which render
// correctly without ever needing mid-frame repositioning.
// Grid/cardinality caps applied while parsing, independent of whatever the
// canvas actually goes on to draw (TermCanvas's own fixed gridCols/gridRows
// only bound painting, not how much this function builds in memory first).
// A real frame at BarWidget's 88x30 grid never comes close to either of
// these -- they exist purely to bound a broken or adversarial stream, not
// to constrain normal output.
var MAX_LINES = 2000
var MAX_LINE_CHARS = 4000

function parseAnsi(raw) {
  var ESC = String.fromCharCode(27)
  var text = String(raw || "")
  var lines = []
  var curLine = []
  var fg = null, bg = null, bold = false
  var buf = ""
  var lineChars = 0

  function flush() {
    if (buf.length > 0) {
      curLine.push({ text: buf, fg: fg, bg: bg, bold: bold })
      buf = ""
    }
  }

  function newline() {
    flush()
    lines.push(curLine)
    curLine = []
    lineChars = 0
  }

  function isCsiTerminator(code) {
    return code >= 0x40 && code <= 0x7E
  }

  var i = 0
  while (i < text.length) {
    if (lines.length >= MAX_LINES) break // frame too tall to be real -- stop building more rows
    var ch = text.charAt(i)

    if (ch === ESC && text.charAt(i + 1) === '[') {
      var j = i + 2
      while (j < text.length && !isCsiTerminator(text.charCodeAt(j))) j++
      if (j >= text.length) break // incomplete sequence at chunk end; drop it

      var terminator = text.charAt(j)
      if (terminator === 'm') {
        // linecast reasserts the current color before nearly every single
        // cell rather than only on actual changes (confirmed directly: a
        // captured radar frame carried 112 SGR sequences across 80 visible
        // characters on one line) -- flushing unconditionally on every 'm'
        // turned each of those into its own one-character segment, which is
        // what made both this parse and TermCanvas's paint loop measurably
        // slow for radar/maps specifically (measured: tens of ms each,
        // confirmed via BarWidget's own render-timer instrumentation).
        // Computing the prospective new state first and only flushing when
        // it's actually different collapses all those redundant resets back
        // into the single real run they represent.
        var codes = text.slice(i + 2, j).split(';')
        var newFg = fg, newBg = bg, newBold = bold
        var k = 0
        while (k < codes.length) {
          var code = parseInt(codes[k], 10) || 0
          if (code === 0) { newFg = null; newBg = null; newBold = false }
          else if (code === 1) { newBold = true }
          else if (code === 22) { newBold = false }
          else if (code === 38 && codes[k + 1] === '2') {
            newFg = { r: parseInt(codes[k + 2], 10) || 0, g: parseInt(codes[k + 3], 10) || 0, b: parseInt(codes[k + 4], 10) || 0 }
            k += 4
          } else if (code === 48 && codes[k + 1] === '2') {
            newBg = { r: parseInt(codes[k + 2], 10) || 0, g: parseInt(codes[k + 3], 10) || 0, b: parseInt(codes[k + 4], 10) || 0 }
            k += 4
          } else if (code === 39) { newFg = null }
          else if (code === 49) { newBg = null }
          k++
        }
        if (!_colorEq(newFg, fg) || !_colorEq(newBg, bg) || newBold !== bold) {
          flush()
          fg = newFg; bg = newBg; bold = newBold
        }
      }
      // Any other terminator (K, H, J, private mode h/l, ...) — no visible
      // effect on a single already-isolated frame; just consume it.
      i = j + 1
      continue
    }

    if (ch === '\n') { newline(); i++; continue }
    if (ch === '\r') { i++; continue }
    if (lineChars < MAX_LINE_CHARS) { buf += ch; lineChars++ } // else: silently drop overflow for this row
    i++
  }
  flush()
  if (curLine.length > 0 || lines.length === 0) lines.push(curLine)

  // Trailing blank lines are just print padding; trim them so the canvas
  // doesn't reserve height for empty rows.
  while (lines.length > 0) {
    var last = lines[lines.length - 1]
    var empty = last.length === 0 || (last.length === 1 && last[0].text.trim() === "")
    if (!empty) break
    lines.pop()
  }

  return lines
}

if (typeof module !== "undefined") {
  module.exports = { parseAnsi: parseAnsi }
}
