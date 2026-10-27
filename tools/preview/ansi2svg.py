#!/usr/bin/env python3
"""Convert 256-color ANSI text into a terminal-window SVG.

usage: ansi2svg.py IN.ansi OUT.svg TITLE [WRAP_COLS]
Lines longer than WRAP_COLS are soft-wrapped at the last space, the way a
narrow terminal would show them.
"""
import re, sys, unicodedata
from html import escape

def xterm(n):
    base = ["#1d1f21", "#cc6666", "#b5bd68", "#f0c674", "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6",
            "#666666", "#d54e53", "#b9ca4a", "#e7c547", "#7aa6da", "#c397d8", "#70c0b1", "#eaeaea"]
    if n < 16:
        return base[n]
    if n < 232:
        n -= 16
        lv = [0, 95, 135, 175, 215, 255]
        return "#%02x%02x%02x" % (lv[n // 36], lv[(n // 6) % 6], lv[n % 6])
    g = 8 + (n - 232) * 10
    return "#%02x%02x%02x" % (g, g, g)

def cells(ch):
    if ch in "️‍":
        return 0
    if unicodedata.east_asian_width(ch) in "WF" or ord(ch) >= 0x1F000:
        return 2
    return 1

SGR = re.compile(r"\x1b\[([0-9;]*)m")

def parse(line):
    """-> list of (text, fg, bold) runs"""
    runs, fg, bold, pos = [], None, False, 0
    for m in SGR.finditer(line):
        if m.start() > pos:
            runs.append((line[pos:m.start()], fg, bold))
        codes = [int(c) for c in m.group(1).split(";") if c] or [0]
        i = 0
        while i < len(codes):
            c = codes[i]
            if c == 0: fg, bold = None, False
            elif c == 1: bold = True
            elif c == 38 and i + 2 < len(codes) and codes[i + 1] == 5:
                fg = xterm(codes[i + 2]); i += 2
            elif 30 <= c <= 37: fg = xterm(c - 30)
            elif 90 <= c <= 97: fg = xterm(c - 90 + 8)
            i += 1
        pos = m.end()
    if pos < len(line):
        runs.append((line[pos:], fg, bold))
    return runs

def wrap(runs, cols):
    """Soft-wrap a run list at the last space before `cols` cells."""
    flat = [(ch, fg, b) for t, fg, b in runs for ch in t]
    out, start = [], 0
    while True:
        # Break preference: the double-space segment gap, then a space before an
        # emoji glyph, then any space, then mid-word.
        w, i, sp, sp_emoji, sp_gap = 0, start, -1, -1, -1
        while i < len(flat) and w + cells(flat[i][0]) <= cols:
            w += cells(flat[i][0])
            if flat[i][0] == " ":
                sp = i
                nxt = flat[i + 1][0] if i + 1 < len(flat) else ""
                if nxt == " ": sp_gap = i
                elif nxt and cells(nxt) == 2: sp_emoji = i
            i += 1
        if i >= len(flat):
            out.append(flat[start:]); break
        cut = next((c for c in (sp_gap, sp_emoji, sp) if c > start), i)
        out.append(flat[start:cut])
        start = cut
        while start < len(flat) and flat[start][0] == " ": start += 1
    res = []
    for seg in out:
        r = []
        for ch, fg, b in seg:
            if r and r[-1][1] == fg and r[-1][2] == b:
                r[-1] = (r[-1][0] + ch, fg, b)
            else:
                r.append((ch, fg, b))
        res.append(r)
    return res

def main():
    src, dst, title = sys.argv[1:4]
    cols = int(sys.argv[4]) if len(sys.argv) > 4 else 10 ** 6
    lines = []
    for raw in open(src, encoding="utf-8").read().rstrip("\n").split("\n"):
        lines.extend(wrap(parse(raw), cols))
    fs, lh, cw = 14, 22, 8.45          # font size, line height, cell width (px)
    pad, bar = 20, 36
    width_cells = max(sum(cells(c) for t, _, _ in l for c in t) for l in lines)
    W = int(pad * 2 + width_cells * cw)
    H = int(bar + pad + len(lines) * lh + pad - 6)
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">',
         '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">'
         '<stop offset="0" stop-color="#14161f"/><stop offset="1" stop-color="#0b0c12"/></linearGradient></defs>',
         f'<rect width="{W}" height="{H}" rx="12" fill="url(#g)" stroke="#2c2f3d"/>',
         f'<rect width="{W}" height="{bar}" rx="12" fill="#1c1e2a"/>',
         f'<rect y="{bar - 12}" width="{W}" height="12" fill="#1c1e2a"/>',
         f'<line x1="0" y1="{bar}" x2="{W}" y2="{bar}" stroke="#2c2f3d"/>',
         '<circle cx="20" cy="18" r="6" fill="#ff5f57"/><circle cx="40" cy="18" r="6" fill="#febc2e"/>'
         '<circle cx="60" cy="18" r="6" fill="#28c840"/>',
         f'<text x="{W / 2}" y="23" text-anchor="middle" fill="#8b8fa3" '
         f'font-family="-apple-system,Segoe UI,Helvetica,Arial,sans-serif" font-size="13">{escape(title)}</text>',
         f'<g font-family="ui-monospace,SFMono-Regular,Menlo,Consolas,\'DejaVu Sans Mono\',monospace" '
         f'font-size="{fs}" xml:space="preserve">']
    y = bar + pad + fs
    for l in lines:
        # Pin every chunk to the cell grid, giving each wide glyph (emoji) its
        # own chunk, so layout never depends on the viewer's font metrics.
        # Plain-text chunks are also stretched to their exact grid width.
        spans, col = [], 0
        for t, fg, b in l:
            attrs = f' fill="{fg or "#e6e6e6"}"' + (' font-weight="bold"' if b else "")
            chunks = []                         # [text, start_col, cells, wide]
            for ch in t:
                w = cells(ch)
                if w == 0 and chunks:           # joiner/VS16 rides on its glyph
                    chunks[-1][0] += ch
                elif w == 2 or not chunks or chunks[-1][3]:
                    chunks.append([ch, col, w, w == 2])
                else:
                    chunks[-1][0] += ch; chunks[-1][2] += w
                col += w
            for text, start, n, wide in chunks:
                fit = "" if wide or not text.strip() else \
                    f' textLength="{n * cw:.1f}" lengthAdjust="spacingAndGlyphs"'
                spans.append(f'<tspan x="{pad + start * cw:.1f}"{fit}{attrs}>{escape(text)}</tspan>')
        o.append(f'<text x="{pad}" y="{y}">{"".join(spans)}</text>')
        y += lh
    o.append("</g></svg>")
    open(dst, "w", encoding="utf-8").write("\n".join(o) + "\n")
    print(dst, W, "x", H, "lines:", len(lines))

main()
