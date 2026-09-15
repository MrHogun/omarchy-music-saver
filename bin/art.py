#!/usr/bin/env python3
"""Turn album art into coloured ASCII, as rich text the shell can draw.

Takes the file MPRIS points at (players cache the cover locally, so this is a
read off disk, not a download), scales it with ffmpeg, and prints one HTML line
per character row: each cell a span coloured like the pixel it stands for, with
a character picked by how bright that pixel is.

A character cell is about twice as tall as it is wide, so the vertical sampling
is halved -- but only after the source's own shape is taken into account. Covers
are not always square: YouTube Music hands out video thumbnails at 16:9, and
assuming a square there squashes them.

Usage: art.py <path-or-url> [cols] [blocks|ascii|dots]
"""
import html
import subprocess
import sys

# Dark to light. Denser glyphs read as brighter areas once they are coloured.
# Shape, not density, is what the eye reads at this size: a ramp of letters and
# punctuation turns a cover into noise because every glyph has a different
# outline. Blocks share one outline and differ only in how much they fill, so
# the picture survives.
RAMPS = {
    "blocks": " \u2591\u2592\u2593\u2588",
    # The old one, kept so the two can be compared side by side.
    "ascii": " .'`^\",:;Il!i><~+_-?][}{1)(|\\/tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B@$",
}

# Braille is not a ramp at all. Each cell carries a 2x4 grid of dots that are
# either there or not, so a cell is eight pixels rather than one -- four times
# the vertical detail of any glyph ramp, which is why every terminal image
# viewer worth using offers it. Brightness is then a matter of how many dots
# are lit, which is what dithering has always been for.
#
# Unicode numbers the dots down the left column and then down the right, with
# the fourth row bolted on at the end, so the bit for a dot is not where its
# position suggests.
BRAILLE_BITS = ((0x01, 0x08), (0x02, 0x10), (0x04, 0x20), (0x40, 0x80))

# A plain threshold posterises a cover into shapeless blobs, and ordered
# dithering over a cell only two dots wide comes out as visible vertical
# striping -- Bayer's left column simply gets the lower thresholds. Floyd and
# Steinberg's error diffusion has no grid to show through, and the cover is
# redrawn only when the track changes, so it never has to be stable frame to
# frame.


# How much taller a character cell is than it is wide. Close enough across the
# monospace families a terminal-styled shell is likely to be using.
CELL_ASPECT = 2.0


def source_shape(path):
    """Width and height of the image, or None if ffprobe cannot say."""
    cmd = ["ffprobe", "-v", "error", "-select_streams", "v:0",
           "-show_entries", "stream=width,height", "-of", "csv=p=0:s=x", path]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout.strip()
        width, height = (int(v) for v in out.split("x")[:2])
        if width > 0 and height > 0:
            return width, height
    except Exception:
        pass
    return None


def sample(path, cols, rows):
    """Scale the image to cols x rows and return it as rows of (r, g, b)."""
    cmd = [
        "ffmpeg", "-v", "error", "-i", path,
        "-vf", f"scale={cols}:{rows}:flags=lanczos",
        "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-",
    ]
    raw = subprocess.run(cmd, capture_output=True, timeout=15).stdout
    if len(raw) < cols * rows * 3:
        return None
    return [
        [tuple(raw[(y * cols + x) * 3:(y * cols + x) * 3 + 3]) for x in range(cols)]
        for y in range(rows)
    ]


def luma_of(r, g, b):
    """Rec. 601: green carries most of the perceived brightness."""
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255.0


def lift(r, g, b, luma):
    """Lift very dark cells so the shape stays visible on a dark backdrop."""
    scale = 1.0 if luma > 0.25 else 1.0 + (0.25 - luma)
    rr, gg, bb = (min(255, int(c * scale)) for c in (r, g, b))
    # Quantising to 5 bits a channel is invisible at this size and lets
    # neighbouring cells share a span.
    return f"#{rr & 0xf8:02x}{gg & 0xf8:02x}{bb & 0xf8:02x}"


def cells_from_ramp(pixels, ramp):
    for row in pixels:
        cells = []
        for r, g, b in row:
            luma = luma_of(r, g, b)
            glyph = ramp[min(len(ramp) - 1, int(luma * len(ramp)))]
            if glyph == " ":
                cells.append((None, "&nbsp;"))
                continue
            cells.append((lift(r, g, b, luma), html.escape(glyph)))
        yield cells


def stretched(pixels, width, height):
    """Luma per pixel, with the cover's own range opened out to fill 0..1.

    One bit per dot has no shades to spare: a cover that lives between 0.1 and
    0.4 luma -- which is most album art -- would lose almost every dot to the
    threshold. So the range is stretched off its own 2nd and 98th percentiles
    (ignoring the few brightest and darkest pixels, which are usually specular
    highlights and black borders) and lifted a little by gamma.
    """
    rows = [[luma_of(*pixels[y][x]) for x in range(width)] for y in range(height)]
    flat = sorted(v for row in rows for v in row)
    lo = flat[int(len(flat) * 0.02)]
    hi = flat[min(len(flat) - 1, int(len(flat) * 0.98))]
    span = max(1e-3, hi - lo)
    return [[min(1.0, max(0.0, (v - lo) / span)) ** 0.8 for v in row] for row in rows]


def dither(pixels, width, height):
    """Floyd-Steinberg the image down to one bit, carrying the error along."""
    rows = stretched(pixels, width, height)
    on = [[False] * width for _ in range(height)]
    for y in range(height):
        for x in range(width):
            value = rows[y][x]
            lit = value > 0.5
            on[y][x] = lit
            error = value - (1.0 if lit else 0.0)
            if x + 1 < width:
                rows[y][x + 1] += error * 7 / 16
            if y + 1 < height:
                if x > 0:
                    rows[y + 1][x - 1] += error * 3 / 16
                rows[y + 1][x] += error * 5 / 16
                if x + 1 < width:
                    rows[y + 1][x + 1] += error * 1 / 16
    return on


def cells_from_braille(pixels, cols, rows):
    """One cell per 2x4 block of pixels: dots dithered, colour averaged."""
    on = dither(pixels, cols * 2, rows * 4)
    for row in range(rows):
        cells = []
        for col in range(cols):
            bits = 0
            lit = []
            for y in range(4):
                for x in range(2):
                    if not on[row * 4 + y][col * 2 + x]:
                        continue
                    bits |= BRAILLE_BITS[y][x]
                    lit.append(pixels[row * 4 + y][col * 2 + x])
            if not bits:
                cells.append((None, "&nbsp;"))
                continue
            # Colour the cell like the dots that are actually lit: averaging the
            # whole block drags every lit dot towards the dark it sits next to.
            count = len(lit)
            r = sum(p[0] for p in lit) / count
            g = sum(p[1] for p in lit) / count
            b = sum(p[2] for p in lit) / count
            cells.append((lift(r, g, b, luma_of(r, g, b)), chr(0x2800 + bits)))
        yield cells


def main():
    if len(sys.argv) < 2:
        return 1
    path = sys.argv[1]
    if path.startswith("file://"):
        path = path[7:]
    cols = int(sys.argv[2]) if len(sys.argv) > 2 else 44
    style = sys.argv[3] if len(sys.argv) > 3 else "blocks"

    shape = source_shape(path)
    if shape:
        width, height = shape
        rows = max(1, round(cols * (height / width) / CELL_ASPECT))
    else:
        rows = max(1, round(cols / CELL_ASPECT))

    # Braille subdivides the cell 2x4, and a cell is about twice as tall as it
    # is wide, so those sub-pixels come out square: the same row count, sampled
    # eight times as densely.
    if style == "dots":
        pixels = sample(path, cols * 2, rows * 4)
        if pixels is None:
            return 1
        grid = cells_from_braille(pixels, cols, rows)
    else:
        pixels = sample(path, cols, rows)
        if pixels is None:
            return 1
        grid = cells_from_ramp(pixels, RAMPS.get(style, RAMPS["blocks"]))

    out = []
    for cells in grid:
        # Emit one span per run of equal colour. A cover has large flat areas,
        # and a span per cell means thousands of them for the text engine to lay
        # out at once -- which is felt as a stutter exactly when a track changes.
        line = []
        run_colour, run_text = cells[0] if cells else (None, "")
        for colour, glyph in cells[1:]:
            if colour == run_colour:
                run_text += glyph
                continue
            line.append(run_text if run_colour is None
                        else f'<span style="color:{run_colour}">{run_text}</span>')
            run_colour, run_text = colour, glyph
        if run_text:
            line.append(run_text if run_colour is None
                        else f'<span style="color:{run_colour}">{run_text}</span>')
        out.append("".join(line))

    print("<br>".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
