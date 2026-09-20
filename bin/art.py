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

The backdrop decides the polarity. On a dark background ink marks the bright
parts of the cover, which is how ASCII art has always been read. On a light one
that is exactly backwards -- pale pixels drawn pale on white are not there at
all -- so ink marks the dark parts instead and the colours are pushed down
rather than lifted.

Usage: art.py <path-or-url> [cols] [blocks|ascii|dots] [dark|light]
       art.py <path-or-url> palette [count]   -- print colours, not art
"""
import colorsys
import html
import os
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

# Everything below bounds the work a cover can ask for. The picture arrives
# from a player's metadata, and a tiny file can declare an enormous shape: a
# 1x8000 PNG is a few hundred bytes and would ask for eight thousand rows,
# which is an ffmpeg frame nobody wanted and a megabyte of markup for the shell
# to lay out. Size limits on the download do not bound that -- the declared
# geometry does. So the geometry is checked first, and anything outside what a
# cover plausibly looks like is refused rather than clamped into something that
# still runs.
MAX_COLS = 200            # the setting caps at 120; this is the script's own floor/ceiling
MAX_ROWS = 120
MAX_CELLS = 14000         # cols x rows actually drawn
MAX_SOURCE_EDGE = 20000   # pixels, either dimension
MIN_ASPECT = 0.2          # width / height
MAX_ASPECT = 5.0
MAX_OUTPUT_BYTES = 2_000_000


# What a player hands us in `mpris:artUrl` is a URL, not a path, and the player
# chose it. Earlier versions fetched remote covers here under a timeout and a
# byte ceiling, but those checks happen *after* the request has left the
# machine: a crafted metadata value could still make this session issue GETs at
# loopback, link-local or private addresses, and redirects and DNS rebinding
# make validating a hostname up front insufficient on its own.
#
# A cover is not worth that. Players cache their art locally -- that is what
# `file://` in the metadata means -- so only local files are read, and anything
# that would require going out on the network is refused. Nothing here opens a
# socket.
def resolve(url):
    """A local path for the cover, or None."""
    if url.startswith("file://"):
        path = url[7:]
    elif "://" in url:
        return None          # http, https, data, anything else: not ours to fetch
    else:
        path = url           # a bare path from a well-behaved player
    return path if os.path.isfile(path) else None


def plausible(width, height):
    """Is this a shape a cover could actually have?"""
    if width <= 0 or height <= 0:
        return False
    if width > MAX_SOURCE_EDGE or height > MAX_SOURCE_EDGE:
        return False
    ratio = width / height
    return MIN_ASPECT <= ratio <= MAX_ASPECT


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


def lift(r, g, b, luma, on_light=False):
    """Keep a cell visible against the backdrop it is drawn on.

    Dark backdrop: lift the very dark cells. Light backdrop: hold every cell
    below the point where its own colour disappears into the page.
    """
    if on_light:
        scale = 1.0 if luma < 0.55 else 0.55 / max(0.01, luma)
    else:
        scale = 1.0 if luma > 0.25 else 1.0 + (0.25 - luma)
    rr, gg, bb = (min(255, int(c * scale)) for c in (r, g, b))
    # Quantising to 5 bits a channel is invisible at this size and lets
    # neighbouring cells share a span.
    return f"#{rr & 0xf8:02x}{gg & 0xf8:02x}{bb & 0xf8:02x}"


def cells_from_ramp(pixels, ramp, on_light=False):
    for row in pixels:
        cells = []
        for r, g, b in row:
            luma = luma_of(r, g, b)
            ink = 1.0 - luma if on_light else luma
            glyph = ramp[min(len(ramp) - 1, int(ink * len(ramp)))]
            if glyph == " ":
                cells.append((None, "&nbsp;"))
                continue
            cells.append((lift(r, g, b, luma, on_light), html.escape(glyph)))
        yield cells


def stretched(pixels, width, height, on_light=False):
    """Luma per pixel, with the cover's own range opened out to fill 0..1.

    One bit per dot has no shades to spare: a cover that lives between 0.1 and
    0.4 luma -- which is most album art -- would lose almost every dot to the
    threshold. So the range is stretched off its own 2nd and 98th percentiles
    (ignoring the few brightest and darkest pixels, which are usually specular
    highlights and black borders) and lifted a little by gamma.
    """
    rows = [[luma_of(*pixels[y][x]) for x in range(width)] for y in range(height)]
    if on_light:
        rows = [[1.0 - v for v in row] for row in rows]
    flat = sorted(v for row in rows for v in row)
    lo = flat[int(len(flat) * 0.02)]
    hi = flat[min(len(flat) - 1, int(len(flat) * 0.98))]
    span = max(1e-3, hi - lo)
    return [[min(1.0, max(0.0, (v - lo) / span)) ** 0.8 for v in row] for row in rows]


def dither(pixels, width, height, on_light=False):
    """Floyd-Steinberg the image down to one bit, carrying the error along."""
    rows = stretched(pixels, width, height, on_light)
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


def cells_from_braille(pixels, cols, rows, on_light=False):
    """One cell per 2x4 block of pixels: dots dithered, colour averaged."""
    on = dither(pixels, cols * 2, rows * 4, on_light)
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
            cells.append((lift(r, g, b, luma_of(r, g, b), on_light),
                          chr(0x2800 + bits)))
        yield cells


# Picking colours out of a cover, for the spectrum to be painted with.
#
# Taking the most common colours outright does not work: covers are mostly
# near-black or near-white, and the average of an image is always mud. What the
# spectrum needs is the opposite -- a few colours that are saturated enough to
# be a colour at all, bright enough to sit on the background without vanishing,
# and far enough apart in hue to read as different from each other.
MIN_SATURATION = 0.22
MIN_VALUE = 0.25
HUE_BUCKETS = 24          # 15 degrees each
MIN_HUE_DISTANCE = 2      # buckets, so 30 degrees between chosen colours


def cover_palette(pixels, count):
    weights = [0.0] * HUE_BUCKETS
    sums = [[0.0, 0.0, 0.0] for _ in range(HUE_BUCKETS)]

    for row in pixels:
        for r, g, b in row:
            h, s, v = colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)
            if s < MIN_SATURATION or v < MIN_VALUE:
                continue
            # Weight by how much of a colour it is: a washed-out pixel counts
            # for less than a vivid one, even where the washed-out ones are the
            # majority -- which on a cover they usually are.
            weight = s * v
            bucket = min(HUE_BUCKETS - 1, int(h * HUE_BUCKETS))
            weights[bucket] += weight
            for i, c in enumerate((r, g, b)):
                sums[bucket][i] += c * weight

    order = sorted(range(HUE_BUCKETS), key=lambda i: weights[i], reverse=True)
    chosen = []
    for bucket in order:
        if weights[bucket] <= 0:
            break
        # Neighbouring hues are the same colour to the eye at this size, and a
        # gradient between them is a gradient between nothing and nothing.
        if any(min(abs(bucket - taken), HUE_BUCKETS - abs(bucket - taken))
               < MIN_HUE_DISTANCE for taken in chosen):
            continue
        chosen.append(bucket)
        if len(chosen) >= count:
            break

    out = []
    for bucket in chosen:
        r, g, b = (c / weights[bucket] for c in sums[bucket])
        h, s, v = colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)
        # The average of a bucket always comes back duller than the pixels in
        # it. Put back enough saturation and brightness that the colour holds
        # its own against a dark background; the consumer still decides the
        # final contrast, because only it knows what the background is.
        s = max(s, 0.55)
        v = max(v, 0.72)
        r, g, b = (int(round(c * 255)) for c in colorsys.hsv_to_rgb(h, s, v))
        out.append((h, f"#{r:02x}{g:02x}{b:02x}"))

    # Hue order, so consumers get a ramp rather than a jumble.
    out.sort(key=lambda pair: pair[0])
    return [colour for _, colour in out]


def main():
    if len(sys.argv) < 2:
        return 1
    path = resolve(sys.argv[1])
    if not path:
        return 1
    return draw(path)


def draw(path):
    if len(sys.argv) > 2 and sys.argv[2] == "palette":
        count = int(sys.argv[3]) if len(sys.argv) > 3 else 5
        # 64 wide is plenty: this is a question about colour, not detail.
        pixels = sample(path, 64, 64)
        if pixels is None:
            return 1
        print(" ".join(cover_palette(pixels, count)))
        return 0

    cols = int(sys.argv[2]) if len(sys.argv) > 2 else 44
    cols = max(8, min(MAX_COLS, cols))
    style = sys.argv[3] if len(sys.argv) > 3 else "blocks"
    on_light = (sys.argv[4] if len(sys.argv) > 4 else "dark") == "light"

    shape = source_shape(path)
    if shape:
        width, height = shape
        # Fail closed: a cover that claims an extreme shape is not a cover.
        if not plausible(width, height):
            return 1
        rows = max(1, round(cols * (height / width) / CELL_ASPECT))
    else:
        # ffprobe could not say, so assume the shape a cover usually has.
        rows = max(1, round(cols / CELL_ASPECT))

    if rows > MAX_ROWS or cols * rows > MAX_CELLS:
        return 1

    # Braille subdivides the cell 2x4, and a cell is about twice as tall as it
    # is wide, so those sub-pixels come out square: the same row count, sampled
    # eight times as densely.
    if style == "dots":
        pixels = sample(path, cols * 2, rows * 4)
        if pixels is None:
            return 1
        grid = cells_from_braille(pixels, cols, rows, on_light)
    else:
        pixels = sample(path, cols, rows)
        if pixels is None:
            return 1
        grid = cells_from_ramp(pixels, RAMPS.get(style, RAMPS["blocks"]), on_light)

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

    drawn = "<br>".join(out)
    # One last ceiling, on the thing the shell actually has to hold and lay
    # out. With the caps above this cannot trigger; it is here so that a future
    # change to them cannot quietly hand the shell a megabyte of markup.
    if len(drawn.encode("utf-8")) > MAX_OUTPUT_BYTES:
        return 1
    print(drawn)
    return 0


if __name__ == "__main__":
    sys.exit(main())
