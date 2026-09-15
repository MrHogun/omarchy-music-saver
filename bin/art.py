#!/usr/bin/env python3
"""Turn album art into coloured ASCII, as rich text the shell can draw.

Takes the file MPRIS points at (players cache the cover locally, so this is a
read off disk, not a download), scales it with ffmpeg, and prints one HTML line
per character row: each cell a span coloured like the pixel it stands for, with
a character picked by how bright that pixel is.

Terminal cells are about twice as tall as they are wide, so the vertical
sampling is halved to keep the picture square.

Usage: art.py <path-or-url> [cols]
"""
import html
import subprocess
import sys

# Dark to light. Denser glyphs read as brighter areas once they are coloured.
RAMP = " .'`^\",:;Il!i><~+_-?][}{1)(|\\/tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B@$"


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
    rows = max(1, cols // 2)

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
