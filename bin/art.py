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

Usage: art.py <path-or-url> [cols]
"""
import html
import subprocess
import sys

# Dark to light. Denser glyphs read as brighter areas once they are coloured.
RAMP = " .'`^\",:;Il!i><~+_-?][}{1)(|\\/tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B@$"


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


def main():
    if len(sys.argv) < 2:
        return 1
    path = sys.argv[1]
    if path.startswith("file://"):
        path = path[7:]
    cols = int(sys.argv[2]) if len(sys.argv) > 2 else 44

    shape = source_shape(path)
    if shape:
        width, height = shape
        rows = max(1, round(cols * (height / width) / CELL_ASPECT))
    else:
        rows = max(1, round(cols / CELL_ASPECT))

    pixels = sample(path, cols, rows)
    if pixels is None:
        return 1

    out = []
    for row in pixels:
        line = []
        for r, g, b in row:
            # Rec. 601 luma: green carries most of the perceived brightness.
            luma = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
            glyph = RAMP[min(len(RAMP) - 1, int(luma * len(RAMP)))]
            if glyph == " ":
                line.append("&nbsp;")
                continue
            # Lift very dark cells so the shape stays visible on a dark backdrop.
            scale = 1.0 if luma > 0.25 else 1.0 + (0.25 - luma)
            rr, gg, bb = (min(255, int(c * scale)) for c in (r, g, b))
            line.append(f'<span style="color:#{rr:02x}{gg:02x}{bb:02x}">'
                        f'{html.escape(glyph)}</span>')
        out.append("".join(line))

    print("<br>".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
