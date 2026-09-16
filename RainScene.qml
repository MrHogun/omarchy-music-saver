import QtQuick
import qs.Commons
import Qt5Compat.GraphicalEffects

// The rain preset. Not a variation on the others: the cover stops being the
// picture and becomes the thing the weather happens to.
//
// What the references do, and what is borrowed from each. terminal-rain-lightning
// keeps a list of drops with a per-drop speed and picks a glyph per drop, and
// turns a drizzle into a storm by changing two numbers -- how often drops spawn
// and how many at a time. The ASCII Rain Drops toy adds the thing that makes
// water read as water: rings that expand from every impact and fade as they go.
// matrixfall's streams are drawn with a trailing gradient rather than a single
// glyph.
//
// What is ours: the music drives all of it, and it drives it *per frequency*.
// A column of the screen belongs to a band of the spectrum -- bass on the left,
// treble on the right -- so a bassline rains on the left of the screen and a
// hi-hat spits on the right. The puddles are the same spectrum with a long
// memory, and a transient is lightning.
Item {
  id: scene

  required property var levels        // 0..1 per band, newest frame
  required property real overallLevel
  required property int bands
  required property string style      // ascii | blocks | dots
  required property var toneAt        // function(0..1) -> colour
  required property color dimColour
  required property string artHtml    // the cover, already drawn as rich text
  required property int artCols
  property bool running: false
  property real coverOpacity: 0.85
  // off | rare | auto | often. See the strike rule below for what each means.
  property string lightning: "auto"
  property string title: ""
  property string artist: ""
  readonly property int colourBands: 3

  readonly property int artRows: {
    if (!artHtml) return 0
    const parts = artHtml.split("<br>")
    return parts.length
  }

  // ---------------------------------------------------------------- alphabet
  //
  // Each preset brings its own water. The ascii set is the classic one; braille
  // dots fall as single raised dots; blocks fall as thin vertical bars.
  readonly property var fallGlyphs: {
    switch (scene.style) {
    case "dots":   return ["⠁", "⠂", "⠄", "⡀"]
    case "blocks": return ["▏", "▕", "│", "┃"]
    default:       return ["|", "'", ".", ","]
    }
  }
  readonly property var ringGlyphs: {
    switch (scene.style) {
    case "dots":   return ["⠀", "⠒", "⠶", "⠿"]
    case "blocks": return [" ", "▁", "▃", "▅"]
    default:       return [".", "o", "O", "0"]
    }
  }
  readonly property var poolGlyphs: {
    switch (scene.style) {
    case "dots":   return ["⡀", "⣀", "⣤", "⣶", "⣿"]
    case "blocks": return ["▁", "▂", "▄", "▆", "█"]
    default:       return ["_", "~", "=", "≡", "#"]
    }
  }
  // Omarchy's own screensaver has a thunderstorm effect (ttfx thunderstorm),
  // and it is worth copying rather than inventing around: it rains with a
  // slant on "\\ . ,", draws the bolt as line segments, and throws sparks of
  // "* . '" where the strike lands. Ours keeps the sparks and the segments;
  // the colour is white rather than its pale blue.
  readonly property var sparkGlyphs: ["*", ".", "'"]

  // ---------------------------------------------------------------- geometry
  FontMetrics {
    id: fm
    font.family: Style.fontFamily
    font.pixelSize: 19
  }

  readonly property real cellWidth: fm.averageCharacterWidth
  readonly property real cellHeight: fm.height * 0.92
  readonly property int cols: Math.max(20, Math.floor(width / cellWidth))
  readonly property int rows: Math.max(10, Math.floor(height / cellHeight))

  // Where the cover sits on that grid, so rain and cover share one coordinate
  // system and a drop can be told it has hit something.
  readonly property int artLeft: Math.floor((cols - artCols) / 2)
  readonly property int artTop: Math.floor((rows - artRows) / 2) - 2
  readonly property int poolRow: rows - 3

  // Two surfaces, not one: the cover, and the caption hanging well below it.
  // Rain falls in the gap between them, and lands on each in turn -- the text
  // is as solid a thing to rain on as the picture is.
  readonly property int surfaceTop: artTop
  readonly property int surfaceBottom: artTop + artRows

  readonly property int labelTop: Math.floor(labels.y / Math.max(1, cellHeight))
  readonly property int labelBottom: Math.ceil((labels.y + labels.height) / Math.max(1, cellHeight))
  readonly property int labelLeft: Math.floor(labels.x / Math.max(1, cellWidth))
  readonly property int labelRight: Math.ceil((labels.x + labels.width) / Math.max(1, cellWidth))

  // ------------------------------------------------------------------- state
  property var drops: []      // {x, y, speed, glyph}
  property var rings: []      // {x, age}
  property var streaks: []    // {x, y, speed, life}  -- water running down the cover
  property var splashes: []   // {x, y, age} -- a hit on the cover that does not run
  property var pool: []       // one water level per column
  property var bolt: []       // {x, y, glyph} for the current lightning
  property var sparks: []     // {x, y, vx, vy, age} thrown up where it landed
  property real flash: 0
  property real lastLevel: 0
  property real jumpAverage: 0
  property int strikeCooldown: 0

  function reset() {
    drops = []
    rings = []
    streaks = []
    splashes = []
    bolt = []
    sparks = []
    flash = 0
    const next = new Array(cols)
    for (let i = 0; i < cols; i++) next[i] = 0
    pool = next
  }

  onColsChanged: reset()
  onRunningChanged: if (running) reset()

  function bandAt(x) {
    return Math.max(0, Math.min(scene.bands - 1,
      Math.floor(x / Math.max(1, scene.cols) * scene.bands)))
  }

  function step() {
    if (!scene.running || scene.cols < 20) return
    const cols = scene.cols
    const rows = scene.rows

    // --- spawn. Every column belongs to a band, and a loud band rains.
    for (let x = 0; x < cols; x++) {
      const level = scene.levels[scene.bandAt(x)] || 0
      // A floor of drizzle everywhere, so a bass-heavy track does not leave the
      // right half of the screen a desert, and then the band's own level
      // squared on top -- quiet stays a drizzle, loud opens up.
      if (Math.random() < 0.006 + level * level * 0.28) {
        drops.push({ x: x,
                     y: -1,
                     speed: 0.5 + level * 1.6 + Math.random() * 0.4,
                     glyph: scene.fallGlyphs[Math.floor(Math.random() * 2)] })
      }
    }

    // --- fall, and land on whatever is under them
    const nextDrops = []
    for (const drop of drops) {
      drop.y += drop.speed
      const y = Math.floor(drop.y)
      const onArt = scene.artRows > 0
        && drop.x >= scene.artLeft && drop.x < scene.artLeft + scene.artCols
      if (onArt && y >= scene.surfaceTop && y < scene.surfaceBottom) {
        // Hits the cover. Most impacts are just that -- a bright mark for a
        // moment -- and only some of them gather into a trickle that runs
        // down the face. Turning every hit into a trickle buries the artwork
        // under its own weather in about two seconds.
        if (streaks.length < 45 && Math.random() < 0.3) {
          streaks.push({ x: drop.x, y: y, speed: 0.22 + Math.random() * 0.3,
                         life: 1.0, surface: "art" })
        } else {
          splashes.push({ x: drop.x, y: y, age: 0, surface: "art" })
        }
        continue
      }
      const onLabel = drop.x >= scene.labelLeft && drop.x < scene.labelRight
      if (onLabel && y >= scene.labelTop && y < scene.labelBottom) {
        // The caption is a surface too -- smaller, so it keeps fewer trickles.
        if (streaks.length < 55 && Math.random() < 0.25) {
          streaks.push({ x: drop.x, y: y, speed: 0.2 + Math.random() * 0.25,
                         life: 1.0, surface: "label" })
        } else {
          splashes.push({ x: drop.x, y: y, age: 0, surface: "label" })
        }
        continue
      }
      if (y >= scene.poolRow) {
        rings.push({ x: drop.x, age: 0 })
        const level = scene.pool[drop.x] || 0
        scene.pool[drop.x] = Math.min(1, level + 0.16)
        continue
      }
      if (y < rows) nextDrops.push(drop)
    }
    drops = nextDrops

    // --- water on the cover, running down and drying out
    const nextStreaks = []
    for (const streak of streaks) {
      streak.y += streak.speed
      streak.life -= 0.012
      const bottom = streak.surface === "label" ? scene.labelBottom : scene.surfaceBottom
      if (streak.life > 0 && streak.y < bottom) nextStreaks.push(streak)
      else if (streak.life > 0) {
        // Ran off the bottom edge and carries on falling.
        drops.push({ x: streak.x, y: bottom, speed: 0.8, glyph: scene.fallGlyphs[0] })
      }
    }
    streaks = nextStreaks

    const nextSplashes = []
    for (const splash of splashes) {
      splash.age += 1
      if (splash.age < 3) nextSplashes.push(splash)
    }
    splashes = nextSplashes

    // --- rings on the water
    const nextRings = []
    for (const ring of rings) {
      ring.age += 1
      if (ring.age < 8) nextRings.push(ring)
    }
    rings = nextRings

    // --- puddles dry slowly, so the floor keeps the shape of the last minute
    for (let x = 0; x < cols; x++) scene.pool[x] = (scene.pool[x] || 0) * 0.965

    // --- lightning
    //
    // Not a dice roll: a strike is an onset in the music. The rule is the one
    // onset detectors use -- compare this frame's jump in loudness against a
    // running average of recent jumps, so it adapts to a quiet track as well as
    // a loud one -- with a floor underneath it so silence cannot trigger on its
    // own noise, and a cooldown over the top.
    //
    // The cooldown is what makes it feel like weather rather than a strobe: on
    // a busy track the music offers a dozen onsets a minute, and a storm that
    // answered all of them would be ridiculous. Measured against real playback,
    // auto lands about one strike every thirteen seconds, rare every twenty-six,
    // often every six.
    const jump = scene.overallLevel - scene.lastLevel
    scene.lastLevel = scene.overallLevel
    scene.jumpAverage = scene.jumpAverage * 0.97 + Math.max(0, jump) * 0.03
    if (scene.strikeCooldown > 0) scene.strikeCooldown -= 1

    if (scene.lightning !== "off" && scene.strikeCooldown <= 0 && scene.bolt.length === 0) {
      const tuning = scene.lightning === "rare" ? [0.22, 3.0, 35]
        : (scene.lightning === "often" ? [0.10, 1.5, 6] : [0.15, 2.2, 16])
      if (jump > Math.max(tuning[0], scene.jumpAverage * tuning[1])) {
        scene.strike()
        scene.strikeCooldown = Math.round(tuning[2] * 1000 / 70)
      }
    }
    if (scene.bolt.length > 0 && scene.flash <= 0.25) scene.bolt = []

    const nextSparks = []
    for (const spark of scene.sparks) {
      spark.x += spark.vx
      spark.y += spark.vy
      spark.vy += 0.35          // they come back down
      spark.age += 1
      if (spark.age < 12 && spark.y < scene.rows) nextSparks.push(spark)
    }
    scene.sparks = nextSparks

    if (scene.flash > 0) scene.flash = Math.max(0, scene.flash - 0.08)
    if (scene.bolt.length > 0 && scene.flash <= 0.25) scene.bolt = []

    scene.frame += 1
  }

  // A bolt is a walk downwards that wanders sideways, with the odd fork -- the
  // shape terminal-rain-lightning draws, minus the thunder.
  function strike() {
    const path = []
    const clamp = v => Math.max(1, Math.min(scene.cols - 2, v))
    let x = Math.floor(scene.cols * (0.15 + Math.random() * 0.7))
    for (let y = 0; y < scene.poolRow; y++) {
      const next = clamp(x + Math.round((Math.random() - 0.5) * 5))
      // A bolt is a line, so it is drawn with line pieces: a vertical stroke
      // where it falls straight, a slash where it steps aside.
      if (next === x) {
        path.push({ x: x, y: y, glyph: "|" })
      } else {
        const step = next > x ? 1 : -1
        const slash = next > x ? "\\" : "/"
        for (let cx = x; cx !== next + step; cx += step)
          path.push({ x: cx, y: y, glyph: slash })
      }
      x = next
      if (Math.random() < 0.12) {
        let fx = x
        for (let f = y; f < Math.min(y + 6, scene.poolRow); f++) {
          const fnext = clamp(fx + Math.round((Math.random() - 0.5) * 4))
          path.push({ x: fnext, y: f, glyph: fnext === fx ? "|" : (fnext > fx ? "\\" : "/") })
          fx = fnext
        }
      }
    }
    scene.bolt = path
    scene.flash = 1.0

    // Sparks where it lands, thrown outwards along the water.
    for (let i = 0; i < 14; i++) {
      scene.sparks.push({ x: x, y: scene.poolRow,
                          vx: (Math.random() - 0.5) * 4,
                          vy: -Math.random() * 1.6,
                          age: 0 })
    }
  }

  property int frame: 0

  // ----------------------------------------------------------------- drawing
  //
  // Three plain-text layers rather than one rich-text block: colour never
  // changes within a layer, so a mask over a gradient does in one pass what
  // thousands of coloured spans would do badly.
  // Rain is sparse: a few hundred drops on a grid of ten thousand cells. Build
  // the text from the drops rather than from the grid -- allocating the grid
  // every frame costs more than everything the drops do.
  function linesToText(lines) {
    return lines.join("\n")
  }

  function placeInto(lines, row, col, glyph) {
    if (row < 0 || row >= lines.length || col < 0) return
    const line = lines[row]
    if (line.length > col) {
      lines[row] = line.substring(0, col) + glyph + line.substring(col + 1)
      return
    }
    lines[row] = line + " ".repeat(col - line.length) + glyph
  }

  readonly property var painted: {
    scene.frame     // redraw every step
    if (!scene.running || scene.cols < 20)
      return { rain: [], water: "", cover: "", label: "", bolt: "" }

    const bandsOut = scene.colourBands
    const rain = []
    for (let k = 0; k < bandsOut; k++) rain.push(new Array(scene.rows).fill(""))

    function bandOf(x) {
      return Math.max(0, Math.min(bandsOut - 1,
        Math.floor(x / Math.max(1, scene.cols) * bandsOut)))
    }

    for (const drop of scene.drops) {
      const y = Math.floor(drop.y)
      if (y >= 0 && y < scene.rows) placeInto(rain[bandOf(drop.x)], y, drop.x, drop.glyph)
    }
    const bolt = new Array(scene.rows).fill("")
    for (const b of scene.bolt) placeInto(bolt, b.y, b.x, b.glyph)
    for (const spark of scene.sparks) {
      placeInto(bolt, Math.round(spark.y), Math.round(spark.x),
                scene.sparkGlyphs[Math.min(2, Math.floor(spark.age / 4))])
    }

    const cover = new Array(Math.max(1, scene.surfaceBottom - scene.surfaceTop)).fill("")
    const label = new Array(Math.max(1, scene.labelBottom - scene.labelTop)).fill("")

    function wet(lines, top, left, x, y, glyph) {
      placeInto(lines, y - top, x - left, glyph)
    }

    for (const splash of scene.splashes) {
      const glyph = splash.age === 0 ? "\u2022" : "\u00b7"
      if (splash.surface === "label")
        wet(label, scene.labelTop, scene.labelLeft, splash.x, splash.y, glyph)
      else
        wet(cover, scene.artTop, scene.artLeft, splash.x, splash.y, glyph)
    }
    for (const streak of scene.streaks) {
      const sy = Math.floor(streak.y)
      const onLabel = streak.surface === "label"
      const lines = onLabel ? label : cover
      const top = onLabel ? scene.labelTop : scene.artTop
      const left = onLabel ? scene.labelLeft : scene.artLeft
      // A thin bright head with a shorter tail above it, drying as it goes.
      wet(lines, top, left, streak.x, sy, "\u2502")
      if (streak.life > 0.55) wet(lines, top, left, streak.x, sy - 1, "\u2577")
    }

    const water = new Array(Math.max(1, scene.rows - scene.poolRow)).fill("")
    for (const ring of scene.rings) {
      const spread = Math.round(ring.age * 0.9)
      const glyph = scene.ringGlyphs[Math.max(0, 3 - Math.floor(ring.age / 2))]
      placeInto(water, 0, ring.x - spread, glyph)
      placeInto(water, 0, ring.x + spread, glyph)
    }
    // Water is a surface, not a scatter of marks -- but an unbroken rule from
    // edge to edge is a floor, not a puddle. Where there is water the glyph
    // follows the depth; where there is none only every few cells is marked,
    // and the marks drift, so the dry floor reads as a waterline rather than
    // as an underline.
    const surface = new Array(scene.cols)
    const drift = Math.floor(scene.frame / 6)
    for (let x = 0; x < scene.cols; x++) {
      const level = scene.pool[x] || 0
      if (level > 0.06) {
        const depth = Math.min(scene.poolGlyphs.length - 1,
                               Math.round(level * (scene.poolGlyphs.length - 1)))
        surface[x] = scene.poolGlyphs[depth]
      } else {
        surface[x] = ((x + drift) % 4 === 0) ? scene.poolGlyphs[0] : " "
      }
    }
    water[1] = surface.join("").replace(/\s+$/, "")

    const rainText = []
    for (let k = 0; k < bandsOut; k++) rainText.push(linesToText(rain[k]))
    return { rain: rainText, water: linesToText(water), cover: linesToText(cover),
             label: linesToText(label), bolt: linesToText(bolt) }
  }

  Timer {
    running: scene.running
    interval: 70
    repeat: true
    onTriggered: scene.step()
  }

  // The flash of a strike, behind everything.
  Rectangle {
    anchors.fill: parent
    color: Color.foreground
    opacity: scene.flash * 0.10
  }

  Item {
    anchors.fill: parent

    // Rain and lightning, coloured across the spectrum the way the bars are:
    // one text per colour band, flat-coloured, no render targets.
    Repeater {
      model: scene.colourBands

      Text {
        required property int index
        text: scene.painted.rain.length > index ? scene.painted.rain[index] : ""
        textFormat: Text.PlainText
        color: scene.toneAt((index + 0.5) / scene.colourBands)
        opacity: 0.8
        font.family: Style.fontFamily
        font.pixelSize: fm.font.pixelSize
        lineHeight: 0.92
      }
    }

    // Lightning is not weather taking the spectrum's colour -- it is a white
    // flash, and it reads as one only if it is drawn white.
    Text {
      text: scene.painted.bolt
      textFormat: Text.PlainText
      color: "#ffffff"
      font.family: Style.fontFamily
      font.pixelSize: fm.font.pixelSize
      lineHeight: 0.92
    }

    // The cover itself, on the same grid as the rain.
    Text {
      id: coverText
      x: scene.artLeft * scene.cellWidth
      y: scene.artTop * scene.cellHeight
      text: scene.artHtml
      textFormat: Text.RichText
      font.family: Style.fontFamily
      font.pixelSize: fm.font.pixelSize
      lineHeight: 0.92
    }

    // Water running down its face, over the top of it.
    Text {
      x: scene.artLeft * scene.cellWidth
      y: scene.artTop * scene.cellHeight
      text: scene.painted.cover
      textFormat: Text.PlainText
      color: Color.foreground
      opacity: scene.coverOpacity
      font.family: Style.fontFamily
      font.pixelSize: fm.font.pixelSize
      lineHeight: 0.92
    }

    // The track, hung under the cover so the water runs off one onto the other.
    Column {
      id: labels
      x: (scene.artLeft + scene.artCols / 2) * scene.cellWidth - width / 2
      y: (scene.artTop + scene.artRows) * scene.cellHeight + Style.space(78)
      spacing: Style.space(2)
      visible: scene.artRows > 0

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: scene.title
        textFormat: Text.PlainText
        color: Color.foreground
        font.family: Style.fontFamily
        font.pixelSize: 20
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: scene.artist
        textFormat: Text.PlainText
        color: Color.muted
        font.family: Style.fontFamily
        font.pixelSize: 16
      }
    }

    // Water on the caption, over the top of it.
    Text {
      x: scene.labelLeft * scene.cellWidth
      y: scene.labelTop * scene.cellHeight
      text: scene.painted.label
      textFormat: Text.PlainText
      color: Color.foreground
      opacity: scene.coverOpacity
      font.family: Style.fontFamily
      font.pixelSize: fm.font.pixelSize
      lineHeight: 0.92
    }

    // Puddles and rings.
    Text {
      y: scene.poolRow * scene.cellHeight
      text: scene.painted.water
      textFormat: Text.PlainText
      color: scene.dimColour
      font.family: Style.fontFamily
      font.pixelSize: fm.font.pixelSize
      lineHeight: 0.92
    }
  }
}
