# Music Saver

An Omarchy screensaver for when music is playing: the album art redrawn as
coloured ASCII, a mirrored spectrum of whatever is actually coming out of the
speakers, and the track it belongs to.

Idle with nothing playing and Omarchy's own screensaver still takes over. This
one only appears when a player reports something is playing.

![kind](https://img.shields.io/badge/omarchy-plugin-blue) ![license](https://img.shields.io/badge/license-MIT-green)

---

## Install

```bash
git clone https://github.com/MrHogun/omarchy-music-saver
cd omarchy-music-saver
./install.sh
omarchy restart shell
```

Try it without waiting out the idle timer:

```bash
omarchy-shell music-saver show
```

Remove it with `./install.sh uninstall`.

Needs `pw-cat` (PipeWire), `ffmpeg` and `python3` — all of which a normal
Omarchy install already has.

---

## What it draws

**Album art as coloured ASCII.** Players cache the cover on disk and point MPRIS
at it, so this reads a local file rather than the network. `ffmpeg` scales it,
and each cell gets a character chosen from a 70-step ramp by luminance, coloured
like the pixel it stands for. Vertical sampling is halved because a character
cell is about twice as tall as it is wide — without that the cover comes out
stretched.

**A mirrored spectrum**, in block glyphs, growing up and down from a centre
line, coloured across the theme's own terminal palette -- cool in the bass,
warm at the top. Five things borrowed from people who have done this well make
it read as music rather than noise:

- *Monstercat smoothing* — each bar pushes its neighbours up, falling off with
  distance. `cava`'s trick; without it 32 narrow bars twitch like needles.
- *Peak markers with slow falloff* — the `▔` hanging above each column marks the
  recent maximum and sinks more slowly than the bar. `cli-visualizer` calls this
  falloff, and it is what turns a spectrum into rhythm.
- *Attack and decay* — bars snap up and ease down, rather than tracking the
  signal exactly. Showing a raw FFT is the classic mistake: it flickers and
  never lines up with what you hear.
- *A-weighting* — the ear is far less sensitive to low frequencies, so an
  unweighted spectrum is all bass: the left slams while the right barely moves.
  Each band is weighted by the standard curve, at 60% strength because the full
  curve kills the bottom two octaves outright.
- *Auto sensitivity* — cava's `autosens`. The analyser remembers how loud the
  last few seconds were and scales to that, so a quiet track still fills the
  display and a loud one does not sit pinned at the top.

**A decrypt intro.** The title and artist land as scrambled glyphs and resolve
into themselves over about a second — the same effect Omarchy's stock
screensaver uses on its wordmark (`ttfx decrypt`).

**Track position** as a rule with a marker, in the same block glyphs.

**Colour comes from the theme, all of it.** The shell surfaces five colours to
QML, and in most themes `accent` sits right next to `urgent` -- a gradient
between them is barely a gradient. So this reads the theme's `colors.toml`
directly and spreads the spectrum across its terminal palette
(green → cyan → magenta → blue → red), with height lifting each towards the
foreground so peaks read as hot. The file is watched, so `omarchy theme set`
recolours everything with no further work.

**It wakes on the same keys the stock screensaver wakes on, and no others.**
That one waits on `read -n1` -- a character from stdin -- so volume and
brightness keys never reach it: they are `XF86` binds with `locked = true`,
handled by the compositor, producing no text. This matches that, so the volume
can be changed or a track skipped without losing the view.

---

## How it fits together

| File | Role |
|---|---|
| `manifest.json` | declares the plugin: `kind: service`, `keepLoaded` |
| `Service.qml` | idle watch, MPRIS, the overlay window, all the drawing |
| `bin/spectrum.py` | reads the default sink's monitor, prints one line of bar levels per frame |
| `bin/art.py` | turns the cover into coloured rich text, once per track |

The spectrum analyser is a plain stdout stream — 32 values in 0..1, about 30
times a second — and useful on its own:

```bash
python3 bin/spectrum.py | head -3
```

There is no numpy: the FFT is a textbook radix-2 over 512 points, a few thousand
operations per frame, which is nothing next to the audio it is reading.

## Commands

```bash
omarchy-shell music-saver show      # open it now
omarchy-shell music-saver hide      # close it
omarchy-shell music-saver playing   # what it thinks is playing
```

It closes on any key, a click, or a mouse move of more than 40 px — enough that
a resting hand does not dismiss it.

## Tuning

| Where | Knob |
|---|---|
| `Service.qml` | `barCount`, `rowCount`, `peakFall`, art width (`"72"`) and `pixelSize` |
| `bin/spectrum.py` | `BARS`, `FPS`, `RISE`, `FALL`, `SPREAD`, `LOW_HZ`, `HIGH_HZ` |
| `bin/art.py` | `RAMP` — the luminance ramp |

## Known edges

- The analyser follows the **default sink**. On an unusual setup — a filter
  chain in front of the hardware, say — check that the default sink is the one
  actually carrying audio, or its monitor will be silent and the bars will sit
  flat.
- Rich text with one span per cell is not free; the cover is redrawn only when
  the track changes, never per frame.
- Omarchy's own idle service keeps running. This overlay sits on the overlay
  layer above it, so the stock screensaver may still be started underneath.

## Credits

Ideas taken from [cava](https://github.com/karlstav/cava) (Monstercat smoothing,
mirrored spectrum) and [cli-visualizer](https://github.com/PosixAlchemist/cli-visualizer)
(peak falloff). Built with [Claude Code](https://claude.com/claude-code).

## License

MIT — see [LICENSE](LICENSE).
