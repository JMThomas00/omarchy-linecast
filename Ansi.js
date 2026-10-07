// ANSI parser for linecast output captured with LINECAST_COLOR=truecolor.
// Handles any CSI sequence (ESC [ ... <terminator>), not just SGR ('m').
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

// Row-addressed, not just sequential: linecast 2.4.0 switched every --live
// view's redraw from streaming lines terminated by '\n' to absolute
// per-row cursor positioning (CSI row;colH before each visible line,
// almost always immediately followed by CSI K to erase it) -- confirmed
// directly, 0 newlines in 6-8s of real --live output from 2.4.0 on. This
// parser tracks which row index content is currently being written into
// (set by H/f) rather than always appending to the last-pushed row, so it
// handles both the old newline-streamed shape and the new cursor-addressed
// one with the same code path. Credit to @db48x for the core insight
// (github.com/JMThomas00/omarchy-linecast/issues/5) -- a row index is
// genuinely enough; no column tracking needed, because every H observed
// in radar/weather/sunshine/moon/maps targets column 1 and is immediately
// followed by K, i.e. "erase from column 1 to end of line" == "clear the
// whole row" -- confirmed by direct capture across all five.
//
// Known gap, same tier as the one this replaces: tides has two small
// sub-row overlays (a live clock and the current tide height) that land
// at a nonzero column with no erase-line, a genuine mid-row partial
// update this parser has no column model for. Rather than a crash or a
// wiped row, a revisited row with no erase in between keeps whatever was
// already there and the new text is appended after it -- the overlay ends
// up concatenated onto the row instead of precisely positioned, which is
// a cosmetic miss on two small badges, not a layout break. Properly
// covering it (and the already-accepted theme-picker-overlay gap this
// comment used to describe alone) means real column tracking too; out of
// scope here since every core dashboard row still renders correctly.
//
// Grid/cardinality caps applied while parsing, independent of whatever the
// canvas actually goes on to draw (TermCanvas's own fixed gridCols/gridRows
// only bound painting, not how much this function builds in memory first).
// A real frame at BarWidget's 88x30 grid never comes close to either of
// these -- they exist purely to bound a broken or adversarial stream, not
// to constrain normal output. A row index past MAX_LINES clamps to the
// last row rather than growing the array further.
var MAX_LINES = 2000
var MAX_LINE_CHARS = 4000

function parseAnsi(raw) {
  var ESC = String.fromCharCode(27)
  var text = String(raw || "")
  var lines = []
  var curLine = []
  var currentRow = 0
  var fg = null, bg = null, bold = false
  var buf = ""
  var lineChars = 0
  // Whether any real content has been written to curLine since the last
  // time we arrived at this row (gotoRow/newline). Distinguishes the two
  // real shapes K (erase-line) shows up in: 2.4.0+ sends it immediately
  // after a fresh CUP, before any content -- there, K means "about to
  // receive this row's full content, discard whatever was carried over."
  // Pre-2.4.0 streams send it *after* writing a row's real content, to
  // erase trailing leftover characters from a previously wider frame at
  // that same row -- there, clearing curLine would destroy the content
  // that was just legitimately written. See the 'K' branch below.
  var wroteThisVisit = false

  function flush() {
    if (buf.length > 0) {
      curLine.push({ text: buf, fg: fg, bg: bg, bold: bold })
      buf = ""
    }
  }

  // Writes curLine back into the row it belongs to before moving away
  // from it -- every row transition (CUP or a bare newline) goes through
  // this, and the final row (wherever parsing ends) is committed once
  // more after the main loop since nothing transitions away from it.
  function commitCurrentRow() {
    flush()
    lines[currentRow] = curLine
  }

  function ensureRow(row) {
    if (row >= MAX_LINES) row = MAX_LINES - 1
    while (lines.length <= row) lines.push([])
    return row
  }

  // CSI row;colH (or the rarer ;f form) -- jump to a row directly. Column
  // is intentionally never read: see the file-header comment for why a
  // row index alone covers every core view. Carries over whatever was
  // already at that row (rather than clearing it) so a revisit without an
  // erase-line in between appends instead of destroying prior content --
  // the graceful-degradation path for the tides overlay gap above. The
  // overwhelmingly common case (a fresh CUP immediately followed by K)
  // clears it anyway, via the 'K' branch below.
  function gotoRow(row) {
    commitCurrentRow()
    currentRow = ensureRow(row)
    curLine = lines[currentRow].slice()
    lineChars = 0
    for (var s = 0; s < curLine.length; s++) lineChars += curLine[s].text.length
    wroteThisVisit = false
  }

  // A bare '\n' always means a genuinely fresh row (the pre-2.4.0
  // newline-streamed shape this still supports) -- unlike gotoRow, it
  // never carries over existing content at the target row.
  function newline() {
    commitCurrentRow()
    currentRow = ensureRow(currentRow + 1)
    curLine = []
    lineChars = 0
    wroteThisVisit = false
  }

  function isCsiTerminator(code) {
    return code >= 0x40 && code <= 0x7E
  }

  var i = 0
  while (i < text.length) {
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
      } else if (terminator === 'H' || terminator === 'f') {
        var posParams = text.slice(i + 2, j).split(';')
        var row = parseInt(posParams[0], 10) || 1
        gotoRow(row - 1)
      } else if (terminator === 'K') {
        // Erase-line shows up in two real, opposite-feeling shapes, and
        // wroteThisVisit is what tells them apart. 2.4.0+ sends it
        // immediately after a fresh CUP, before any content -- nothing
        // has been written to curLine yet this visit, so "erase from
        // column 1 to end of line" means the whole row: discard whatever
        // gotoRow carried over. Pre-2.4.0 streams instead send it *after*
        // a row's real content, to erase trailing leftover characters
        // from a previously wider frame at that row -- content has
        // already been written this visit, so clearing curLine now would
        // destroy what was just legitimately flushed into it; since we
        // don't track a real column we can't know what (if anything) lies
        // beyond that content to erase, so the correct move is nothing.
        if (!wroteThisVisit) {
          flush()
          curLine = []
          lineChars = 0
        }
      }
      // Any other terminator (J, private mode h/l, ...) — no visible
      // effect on a single already-isolated frame; just consume it.
      i = j + 1
      continue
    }

    if (ch === '\n') { newline(); i++; continue }
    if (ch === '\r') { i++; continue }
    if (lineChars < MAX_LINE_CHARS) { buf += ch; lineChars++; wroteThisVisit = true } // else: silently drop overflow for this row
    i++
  }
  commitCurrentRow()
  if (lines.length === 0) lines.push([])

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
