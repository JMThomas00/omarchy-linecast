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
function parseAnsi(raw) {
  var ESC = String.fromCharCode(27)
  var text = String(raw || "")
  var lines = []
  var curLine = []
  var fg = null, bg = null, bold = false
  var buf = ""

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
        var codes = text.slice(i + 2, j).split(';')
        flush()
        var k = 0
        while (k < codes.length) {
          var code = parseInt(codes[k], 10) || 0
          if (code === 0) { fg = null; bg = null; bold = false }
          else if (code === 1) { bold = true }
          else if (code === 22) { bold = false }
          else if (code === 38 && codes[k + 1] === '2') {
            fg = { r: parseInt(codes[k + 2], 10) || 0, g: parseInt(codes[k + 3], 10) || 0, b: parseInt(codes[k + 4], 10) || 0 }
            k += 4
          } else if (code === 48 && codes[k + 1] === '2') {
            bg = { r: parseInt(codes[k + 2], 10) || 0, g: parseInt(codes[k + 3], 10) || 0, b: parseInt(codes[k + 4], 10) || 0 }
            k += 4
          } else if (code === 39) { fg = null }
          else if (code === 49) { bg = null }
          k++
        }
      }
      // Any other terminator (K, H, J, private mode h/l, ...) — no visible
      // effect on a single already-isolated frame; just consume it.
      i = j + 1
      continue
    }

    if (ch === '\n') { newline(); i++; continue }
    if (ch === '\r') { i++; continue }
    buf += ch
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
