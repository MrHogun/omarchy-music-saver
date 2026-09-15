#!/usr/bin/env python3
"""Print a spectrum of whatever is coming out of the speakers, one frame per line.

Reads the default sink's monitor through pw-cat and emits BARS values in 0..1,
space separated, about FPS times a second. Written for the shell plugin next to
it, but it is a plain stdout stream and useful on its own.

No numpy: the FFT here is a textbook radix-2, which at 512 points costs a few
thousand operations per frame -- nothing next to the audio it is reading.
"""
import cmath
import math
import os
import struct
import subprocess
import sys

RATE = 22050          # plenty for a 12 kHz top end, and a quarter of the work
CHUNK = 512           # 43 Hz per bin; the log spacing below hides the coarseness
BARS = 32
FPS = 30
LOW_HZ = 45.0
HIGH_HZ = 12000.0
FLOOR_DB = -62.0      # below this a band reads as silence
RISE = 0.55           # how fast a bar climbs towards a new peak
FALL = 0.12           # and how slowly it comes back down
SPREAD = 1.7          # Monstercat smoothing: how sharply a peak decays sideways


def default_monitor():
    """The monitor source of whatever sink audio is currently going to."""
    try:
        out = subprocess.run(["pactl", "info"], capture_output=True, text=True, timeout=5).stdout
        for line in out.splitlines():
            if line.startswith("Default Sink:"):
                return line.split(":", 1)[1].strip() + ".monitor"
    except Exception:
        pass
    return None


def fft(samples):
    """In-place iterative radix-2 Cooley-Tukey. len(samples) must be a power of two."""
    n = len(samples)
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j |= bit
        if i < j:
            samples[i], samples[j] = samples[j], samples[i]

    length = 2
    while length <= n:
        angle = -2j * cmath.pi / length
        step = cmath.exp(angle)
        for start in range(0, n, length):
            w = 1 + 0j
            half = length >> 1
            for k in range(start, start + half):
                even = samples[k]
                odd = samples[k + half] * w
                samples[k] = even + odd
                samples[k + half] = even - odd
                w *= step
        length <<= 1
    return samples


def band_edges():
    """Log-spaced band boundaries, as FFT bin indices."""
    edges = []
    for i in range(BARS + 1):
        hz = LOW_HZ * (HIGH_HZ / LOW_HZ) ** (i / BARS)
        edges.append(min(CHUNK // 2 - 1, max(1, int(hz * CHUNK / RATE))))
    # Neighbouring low bands can collapse onto the same bin; nudge them apart so
    # every bar has at least one bin of its own.
    for i in range(1, len(edges)):
        if edges[i] <= edges[i - 1]:
            edges[i] = edges[i - 1] + 1
    return edges


def main():
    monitor = default_monitor()
    if not monitor:
        print("no default sink found", file=sys.stderr)
        return 1

    cmd = ["pw-cat", "--record", "--target", monitor, "--rate", str(RATE),
           "--channels", "1", "--format", "f32", "--raw", "-"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

    edges = band_edges()
    window = [0.5 - 0.5 * math.cos(2 * math.pi * i / (CHUNK - 1)) for i in range(CHUNK)]
    levels = [0.0] * BARS
    frame_bytes = CHUNK * 4
    # Drop whole frames when the reader falls behind rather than lagging further.
    skip = max(1, int(RATE / (CHUNK * FPS)))

    try:
        while True:
            raw = proc.stdout.read(frame_bytes)
            if not raw or len(raw) < frame_bytes:
                break
            for _ in range(skip - 1):
                if len(proc.stdout.read(frame_bytes) or b"") < frame_bytes:
                    return 0

            samples = list(struct.unpack(f"{CHUNK}f", raw))
            spectrum = fft([complex(s * w, 0.0) for s, w in zip(samples, window)])

            for b in range(BARS):
                lo, hi = edges[b], edges[b + 1]
                peak = 0.0
                for k in range(lo, hi):
                    peak = max(peak, abs(spectrum[k]))
                # Loudness is logarithmic; so is hearing. Map dB onto 0..1.
                db = 20 * math.log10(peak / (CHUNK / 2) + 1e-12)
                value = max(0.0, min(1.0, (db - FLOOR_DB) / -FLOOR_DB))
                # Bars that snap up and ease down read as music; bars that follow
                # the signal exactly read as noise.
                rate = RISE if value > levels[b] else FALL
                levels[b] += (value - levels[b]) * rate

            # Monstercat smoothing, as cava does it: let every bar push its
            # neighbours up, falling off with distance. Without it a spectrum
            # this narrow reads as a row of twitching needles rather than a wave.
            smoothed = list(levels)
            for b in range(BARS):
                for d in range(1, 4):
                    weight = SPREAD ** d
                    if b - d >= 0:
                        smoothed[b - d] = max(smoothed[b - d], levels[b] / weight)
                    if b + d < BARS:
                        smoothed[b + d] = max(smoothed[b + d], levels[b] / weight)

            print(" ".join(f"{v:.3f}" for v in smoothed), flush=True)
    except (BrokenPipeError, KeyboardInterrupt):
        pass
    finally:
        proc.terminate()
    return 0


if __name__ == "__main__":
    sys.exit(main())
