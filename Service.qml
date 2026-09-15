import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Mpris
import qs.Commons
import Qt5Compat.GraphicalEffects

// Music Saver: while something is playing, idling into the screensaver should
// show what is playing rather than a terminal animation.
//
// The stock idle service keeps doing its job; this one watches the same idle
// signal and, only when a player reports Playing, puts a fullscreen spectrum on
// the overlay layer. Any key or a deliberate mouse move takes it away again.
Scope {
  id: root

  // Injected by the shell when the service is created.
  property var shell: null
  property var manifest: null

  // Third-party plugins get no settings handed to them: the shell injects the
  // manifest and a capability-scoped shell api, and nothing else. Per the
  // shell's storage rules the user's values live inline on this plugin's entry
  // in shell.json, so read them from there and take the defaults out of our own
  // manifest, which keeps one declaration of what the options are.
  property var settings: root.defaults()

  function defaults() {
    const declared = root.manifest && root.manifest.settings
      ? root.manifest.settings.defaults : null
    return declared ? JSON.parse(JSON.stringify(declared)) : {}
  }

  function readSettings(parsed) {
    const merged = root.defaults()
    const id = root.manifest ? root.manifest.id : "mrhogun.music-saver"
    const entries = parsed && Array.isArray(parsed.plugins) ? parsed.plugins : []
    for (const entry of entries) {
      if (!entry || entry.id !== id)
        continue
      for (const key in entry)
        if (key !== "id")
          merged[key] = entry[key]
      break
    }
    root.settings = merged
  }

  // Writing goes back through the shell rather than to the file: shell.json is
  // the shell's to own, and updateEntryInline is the sanctioned way in.
  function writeSetting(key, value) {
    if (!root.shell || typeof root.shell.updateEntryInline !== "function")
      return false
    const patch = {}
    patch[key] = value
    return root.shell.updateEntryInline(
      root.manifest ? root.manifest.id : "mrhogun.music-saver", patch)
  }

  // The style preset decides the alphabet the whole screen speaks: "ascii" the
  // classic 70-glyph density ramp, "blocks" the five shaded blocks, "dots"
  // braille -- eight dots to a cell, so the cover is dithered rather than
  // ramped.
  readonly property var styles: ["ascii", "blocks", "dots"]
  readonly property string style: {
    const want = String(root.settings.style || "")
    return root.styles.indexOf(want) !== -1 ? want : "ascii"
  }
  readonly property int artWidth: {
    const width = parseInt(root.settings.artWidth)
    return isNaN(width) ? 72 : Math.max(24, Math.min(120, width))
  }

  onManifestChanged: shellConfig.reload()

  readonly property int barCount: 32
  readonly property int rowCount: 8
  property var levels: new Array(32).fill(0)
  property var peaks: new Array(32).fill(0)
  property real overallLevel: 0

  // Drawn the way terminal visualisers draw: a spectrum mirrored about its
  // centre line and a peak marker per column that falls slowly behind the music
  // -- the trick cli-visualizer calls falloff, and the thing that makes a
  // spectrum read as rhythm rather than noise.
  //
  // How it is drawn is a setting of its own, defaulting to whatever the style
  // preset implies. Every variant below is one line of the same data; they
  // differ only in which alphabet says it.

  // Blocks fill a cell from the bottom in eighths: the smooth bar everyone
  // knows, and the reason terminal visualisers look like they do.
  readonly property var rampBlocks: [" ", "\u2581", "\u2582", "\u2583", "\u2584",
                                     "\u2585", "\u2586", "\u2587", "\u2588"]

  // ASCII cannot move ink within a cell -- but it can pick a glyph whose ink
  // already sits where the fill would be, which is the trick aalib plays on a
  // whole image. The upper half climbs from glyphs resting on the baseline to
  // ones standing full height; the reflection hangs from the top of its cell. A
  // full cell is a bar, so it gets the one glyph that is a bar.
  readonly property var rampAsciiUp: [" ", "_", ".", ",", ":", ";", "i", "|", "|"]
  readonly property var rampAsciiDown: [" ", "'", "\"", "^", ":", ";", "!", "|", "|"]

  // The other way ASCII has always shown a quantity: by weight of ink, with no
  // regard for where in the cell it lands. Reads as a heat map more than a bar.
  readonly property var rampDensity: [" ", ".", ",", ":", ";", "=", "+", "*", "#"]

  // Braille packs four rows into one cell, which is how btop and gotop draw
  // graphs that look smoother than the terminal grid should allow.
  readonly property var rampDotsUp: [" ", "\u2840", "\u2844", "\u28c0", "\u28e4",
                                     "\u28f6", "\u28f6", "\u28ff", "\u28ff"]
  readonly property var rampDotsDown: [" ", "\u2809", "\u2811", "\u2819", "\u281b",
                                       "\u283f", "\u283f", "\u28ff", "\u28ff"]

  readonly property var spectrumStyles: ["bars", "ascii", "density", "wave", "dots"]

  readonly property string spectrumStyle: {
    const want = String(root.settings.spectrum || "")
    if (root.spectrumStyles.indexOf(want) !== -1)
      return want
    switch (root.style) {
    case "dots":   return "dots"
    case "blocks": return "bars"
    default:       return "ascii"
    }
  }

  function rampFor(lower) {
    switch (root.spectrumStyle) {
    case "ascii":   return lower ? root.rampAsciiDown : root.rampAsciiUp
    case "density": return root.rampDensity
    case "dots":    return lower ? root.rampDotsDown : root.rampDotsUp
    default:        return root.rampBlocks
    }
  }

  // The falloff marker rides above the bar, so it wants a glyph that sits high
  // in its cell; its reflection wants one that sits low.
  readonly property string peakUp: {
    switch (root.spectrumStyle) {
    case "ascii":   return "-"
    case "density": return "-"
    case "dots":    return "\u2809"
    default:        return "\u2594"
    }
  }
  readonly property string peakDown: {
    switch (root.spectrumStyle) {
    case "ascii":   return "_"
    case "density": return "-"
    case "dots":    return "\u2840"
    default:        return "\u2581"
    }
  }
  readonly property real peakFall: 0.012

  // A preset change has to redraw the current frame, not wait for the next one:
  // the analyser only runs while the saver is up.
  onSpectrumStyleChanged: root.frame = root.render()
  onStyleChanged: root.frame = root.render()

  readonly property int bandCount: 4

  // Frequency picks the colour, height picks how bright it burns, and the
  // lower half is a reflection rather than a second spectrum.
  function bandColour(tone, reach, lower) {
    let base
    if (root.palette.length >= 2) {
      const span = (root.palette.length - 1) * Math.min(0.999, tone)
      const stop = Math.floor(span)
      base = Qt.tint(root.palette[stop],
                     Qt.rgba(0, 0, 0, 0))
      const next = Qt.color(root.palette[stop + 1])
      const here = Qt.color(root.palette[stop])
      const t = span - stop
      base = Qt.rgba(here.r + (next.r - here.r) * t,
                     here.g + (next.g - here.g) * t,
                     here.b + (next.b - here.b) * t, 1)
    } else {
      base = Color.accent
    }
    // Tips lift towards the foreground so peaks read as hot.
    const lift = reach * 0.45
    return Qt.rgba(
      base.r + (Color.foreground.r - base.r) * lift,
      base.g + (Color.foreground.g - base.g) * lift,
      base.b + (Color.foreground.b - base.b) * lift,
      (lower ? 0.38 : 1.0) * (1.0 - 0.2 * reach))
  }

  function glyphFor(cell, lower) {
    const ramp = root.rampFor(lower)
    if (cell >= 1)
      return ramp[8]
    if (cell > 0)
      return ramp[Math.max(1, Math.round(cell * 8))]
    return " "
  }

  // A contour rather than a bar chart: one glyph per column tracing the top of
  // the spectrum, sloping into its neighbours the way an oscilloscope trace
  // does. The oldest way to draw a curve in text, and the quietest.
  function renderWave() {
    const upper = []
    const lower = []
    const tops = []
    for (let col = 0; col < root.barCount; col++)
      tops.push(Math.max(1, Math.ceil((root.levels[col] || 0) * root.rowCount)))

    function glyphAt(col, fromCentre, lower) {
      const here = tops[col]
      const before = col > 0 ? tops[col - 1] : here
      const after = col < root.barCount - 1 ? tops[col + 1] : here
      if (fromCentre === here) {
        const rise = (after - before) / 2
        if (rise > 0.5) return lower ? "\\" : "/"
        if (rise < -0.5) return lower ? "/" : "\\"
        return lower ? "-" : "_"
      }
      // A step of more than one row leaves a gap the eye reads as a broken
      // line, so the riser between two columns is drawn in.
      const drop = Math.max(before, after)
      if (fromCentre < here && fromCentre > Math.min(before, after)
          && fromCentre < drop)
        return "|"
      return " "
    }

    for (let row = 0; row < root.rowCount; row++) {
      const fromCentre = root.rowCount - row
      let line = ""
      for (let col = 0; col < root.barCount; col++)
        line += glyphAt(col, fromCentre, false) + " "
      upper.push(line)
    }

    for (let row = 0; row < root.rowCount; row++) {
      const fromCentre = row + 1
      let line = ""
      for (let col = 0; col < root.barCount; col++)
        line += glyphAt(col, fromCentre, true) + " "
      lower.push(line)
    }

    return { upper: upper.join("\n"), lower: lower.join("\n") }
  }

  function render() {
    if (root.spectrumStyle === "wave")
      return root.renderWave()
    const upper = []
    const lower = []

    // Upper half: row 0 is the top, so it stands for the loudest level.
    for (let row = 0; row < root.rowCount; row++) {
      const fromCentre = root.rowCount - row
      let line = ""
      for (let col = 0; col < root.barCount; col++) {
        const level = (root.levels[col] || 0) * root.rowCount
        const peak = Math.ceil((root.peaks[col] || 0) * root.rowCount)
        const cell = level - (fromCentre - 1)
        let glyph = glyphFor(cell, false)
        if (glyph === " " && peak === fromCentre)
          glyph = root.peakUp
        line += glyph + " "
      }
      upper.push(line)
    }

    // Lower half: the same columns reflected, so the loud end sits at the edges.
    for (let row = 0; row < root.rowCount; row++) {
      const fromCentre = row + 1
      let line = ""
      for (let col = 0; col < root.barCount; col++) {
        const level = (root.levels[col] || 0) * root.rowCount
        const peak = Math.ceil((root.peaks[col] || 0) * root.rowCount)
        const cell = level - (fromCentre - 1)
        let glyph = glyphFor(cell, true)
        if (glyph === " " && peak === fromCentre)
          glyph = root.peakDown
        line += glyph + " "
      }
      lower.push(line)
    }

    return { upper: upper.join("\n"), lower: lower.join("\n") }
  }


  property var frame: render()

  // Colour is static -- it never changes between frames -- so splitting the
  // spectrum into a grid of coloured text items meant paying for dozens of text
  // layouts a second to achieve something the GPU can do once. Each half is now
  // a single text block, used as a mask over a gradient.
  function paletteAt(i) {
    if (root.palette.length > i)
      return root.palette[i]
    return Color.accent
  }
  onLevelsChanged: {
    const next = []
    for (let i = 0; i < root.barCount; i++) {
      const level = root.levels[i] || 0
      const previous = root.peaks[i] || 0
      next.push(level >= previous ? level : Math.max(level, previous - root.peakFall))
    }
    root.peaks = next
    let sum = 0
    for (let i = 0; i < root.barCount; i++)
      sum += root.levels[i] || 0
    root.overallLevel = Math.min(1, sum / root.barCount * 3)
    frame = render()
  }
  property bool showing: false

  // Follow the user's own screensaver timing rather than inventing one.
  property int idleSeconds: 150

  // Prefer whatever is playing, but fall back to any player that still has a
  // track loaded. Binding everything to "is playing" meant a pause emptied the
  // title, the artist and the cover, and resuming had to rebuild all of it.
  readonly property var player: {
    const players = Mpris.players ? Mpris.players.values : []
    for (const p of players) {
      if (p && p.playbackState === MprisPlaybackState.Playing)
        return p
    }
    for (const p of players) {
      if (p && (p.trackTitle || p.trackArtist))
        return p
    }
    return null
  }

  readonly property bool anyPlaying: {
    const players = Mpris.players ? Mpris.players.values : []
    for (const p of players) {
      if (p && p.playbackState === MprisPlaybackState.Playing)
        return true
    }
    return false
  }

  readonly property bool musicPlaying: anyPlaying
  readonly property string title: player ? (player.trackTitle || "") : ""
  readonly property string artist: player ? (player.trackArtist || "") : ""
  readonly property string artUrl: player ? (player.trackArtUrl || "") : ""

  // Between tracks the player reports empty metadata for a moment. Letting that
  // through empties the labels, the row collapses, and everything above it
  // jumps down and back. Keep the last real values until new ones arrive.
  property string heldTitle: ""
  property string heldArtist: ""
  onTitleChanged: {
    if (!title)
      return
    heldTitle = title
    if (root.showing)
      revealAnimation.restart()
  }
  onArtistChanged: if (artist) heldArtist = artist
  property string artHtml: ""      // what is on screen
  property string artIncoming: ""  // what is fading in over it

  // Omarchy's own screensaver animates its wordmark with ttfx effects --
  // decrypt, beams, laseretch. This borrows the first: the title lands as
  // scrambled glyphs and resolves into itself.
  readonly property string scrambleChars: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789#%&*+=-_/\\|"
  property real revealProgress: 1.0

  readonly property real trackPosition: player && player.position ? player.position : 0
  readonly property real trackLength: player && player.length ? player.length : 0

  function scrambled(text) {
    if (root.revealProgress >= 1 || !text)
      return text
    const settled = Math.floor(text.length * root.revealProgress)
    let out = text.slice(0, settled)
    for (let i = settled; i < text.length; i++) {
      if (text[i] === " ") {
        out += " "
        continue
      }
      const pick = Math.floor(Math.random() * root.scrambleChars.length)
      out += root.scrambleChars[pick]
    }
    return out
  }

  function clock(seconds) {
    const total = Math.max(0, Math.floor(seconds))
    const mins = Math.floor(total / 60)
    const secs = total % 60
    return mins + ":" + (secs < 10 ? "0" : "") + secs
  }

  // A plain rule with a marker on it, in the same glyphs as everything else.
  function progressLine(width) {
    const rule = root.style === "ascii" ? "-"
      : (root.style === "dots" ? "\u2824" : "\u2500")
    const mark = root.style === "ascii" ? "o"
      : (root.style === "dots" ? "\u28ff" : "\u25c6")
    if (root.trackLength <= 0)
      return ""
    const ratio = Math.max(0, Math.min(1, root.trackPosition / root.trackLength))
    const at = Math.round(ratio * (width - 1))
    let line = ""
    for (let i = 0; i < width; i++)
      line += i === at ? mark : rule
    return line
  }

  function dismiss() {
    root.showing = false
  }

  NumberAnimation {
    id: revealAnimation
    target: root
    property: "revealProgress"
    from: 0
    to: 1
    duration: 1100
    easing.type: Easing.OutCubic
  }

  Timer {
    id: scrambleTicker
    interval: 45
    repeat: true
    running: root.showing && root.revealProgress < 1
    onTriggered: root.revealProgressChanged()
  }

  Timer {
    id: positionTicker
    interval: 1000
    repeat: true
    running: root.showing
    onTriggered: if (root.player && root.player.positionSupported) root.player.positionChanged()
  }

  // The shell's Color singleton carries foreground, background, accent, urgent
  // and muted -- and in most themes accent sits right next to urgent, so a
  // gradient between them is barely a gradient at all. The theme itself ships a
  // full terminal palette, so read that and spread the spectrum across it.
  property var palette: []

  FileView {
    id: themeColors
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    onLoaded: {
      const found = {}
      for (const line of text().split("\n")) {
        const match = line.match(/^\s*([a-z_]+)\s*=\s*"(#[0-9a-fA-F]{6})"/)
        if (match)
          found[match[1]] = match[2]
      }
      // Cool to warm, which is the direction a spectrum reads in.
      const order = ["green", "cyan", "magenta", "blue", "red"]
      const ramp = []
      for (const name of order) {
        if (found[name])
          ramp.push(found[name])
      }
      root.palette = ramp.length >= 2 ? ramp : []
    }
    onLoadFailed: root.palette = []
  }

  FileView {
    id: shellConfig
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      try {
        const parsed = JSON.parse(text())
        const seconds = parsed && parsed.idle ? parsed.idle.screensaver : null
        if (typeof seconds === "number" && seconds > 0)
          root.idleSeconds = seconds
        root.readSettings(parsed)
      } catch (e) {
        // A malformed shell.json is the shell's problem to report, not ours;
        // fall back to the default rather than failing to load.
      }
    }
  }

  // So it can be summoned without waiting out the idle timer:
  //   omarchy-shell music-saver show
  IpcHandler {
    target: "music-saver"

    function show(): void {
      root.showing = true
      revealAnimation.restart()
    }

    function hide(): void {
      root.dismiss()
    }

    function playing(): string {
      return root.musicPlaying ? (root.title + " - " + root.artist) : "nothing playing"
    }

    // omarchy-shell music-saver config -> the values in force
    function config(): string {
      return JSON.stringify(root.settings)
    }

    // omarchy-shell music-saver spectrum bars|ascii|density|wave|dots|auto
    function spectrum(name: string): string {
      if (!name)
        return root.spectrumStyle
      if (name !== "auto" && root.spectrumStyles.indexOf(name) === -1)
        return "unknown spectrum: " + name + " (auto, " + root.spectrumStyles.join(", ") + ")"
      if (!root.writeSetting("spectrum", name))
        return "could not write shell.json"
      return name
    }

    // omarchy-shell music-saver style ascii|blocks
    function style(name: string): string {
      if (!name)
        return root.style
      if (root.styles.indexOf(name) === -1)
        return "unknown style: " + name + " (" + root.styles.join(", ") + ")"
      if (!root.writeSetting("style", name))
        return "could not write shell.json"
      return name
    }

    function artWidth(columns: string): string {
      if (!columns)
        return String(root.artWidth)
      const width = parseInt(columns)
      if (isNaN(width) || width < 24 || width > 120)
        return "artWidth must be between 24 and 120"
      if (!root.writeSetting("artWidth", width))
        return "could not write shell.json"
      return String(width)
    }
  }

  IdleMonitor {
    enabled: root.musicPlaying
    timeout: root.idleSeconds
    respectInhibitors: true
    onIsIdleChanged: {
      if (isIdle && root.musicPlaying) {
        root.showing = true
        revealAnimation.restart()
      }
      else if (!isIdle)
        root.dismiss()
    }
  }

  // Album art, redrawn as coloured ASCII whenever the track changes. Players
  // cache the cover on disk, so this reads a local file rather than the network.
  Process {
    id: artRender
    command: ["python3", Quickshell.env("HOME")
      + "/.config/omarchy/plugins/mrhogun.music-saver/bin/art.py", root.artUrl,
      String(root.artWidth), root.style]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        const drawn = text.trim()
        if (!drawn) {
          root.artRendered = ""   // let the next change try again
          return
        }
        if (!root.artHtml) {
          root.artHtml = drawn    // nothing to cross from on the first track
          return
        }
        root.artIncoming = drawn
        artFade.restart()
      }
    }
  }

  property string artRendered: ""

  // Dip out, swap, come back. Cross-fading meant two rich-text blocks of about
  // eight hundred spans each laid out at once, and that lands as a stutter on
  // every track change -- which is exactly when it is most visible.
  SequentialAnimation {
    id: artFade
    NumberAnimation {
      target: artCurrent; property: "opacity"
      to: 0; duration: 220; easing.type: Easing.InQuad
    }
    ScriptAction {
      script: {
        root.artHtml = root.artIncoming
        root.artIncoming = ""
      }
    }
    NumberAnimation {
      target: artCurrent; property: "opacity"
      to: 1; duration: 320; easing.type: Easing.OutQuad
    }
  }

  // What the cover on screen was drawn from. A style or width change has to
  // redraw the same track, so key the cache on everything the drawing depends
  // on rather than on the url alone.
  readonly property string artSignature: root.artUrl + "|" + root.style + "|" + root.artWidth

  function refreshArt() {
    // Track changes can blank the url for a moment, and a pause used to blank it
    // for good. Neither should take the cover off the screen: hold the last one
    // until a new one has actually been drawn.
    if (!root.showing || !root.artUrl || root.artSignature === root.artRendered)
      return
    root.artRendered = root.artSignature
    // Toggling running twice inside one frame collapses to no change at all,
    // so let the stop settle before asking for the next draw.
    artRender.running = false
    Qt.callLater(function() { artRender.running = true })
  }

  onArtSignatureChanged: refreshArt()

  onShowingChanged: refreshArt()

  // The analyser only runs while the saver is up: no point reading the speakers
  // for a window nobody is looking at.
  Process {
    id: spectrum
    running: root.showing
    command: ["python3", Quickshell.env("HOME")
      + "/.config/omarchy/plugins/mrhogun.music-saver/bin/spectrum.py"]
    stdout: SplitParser {
      onRead: line => {
        const parts = line.trim().split(" ")
        if (parts.length < root.barCount)
          return
        const next = []
        for (let i = 0; i < root.barCount; i++)
          next.push(parseFloat(parts[i]) || 0)
        root.levels = next
      }
    }
  }

  PanelWindow {
    id: saver
    visible: root.showing
    anchors { top: true; bottom: true; left: true; right: true }
    color: Color.background
    WlrLayershell.namespace: "omarchy-music-saver"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.showing ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Item {
      anchors.fill: parent
      focus: root.showing
      // Wake on the same keys the stock screensaver wakes on, and no others.
      // That one waits on `read -n1`, a character from stdin, so volume and
      // brightness keys never reach it -- they are XF86 binds with locked=true,
      // handled by the compositor and producing no text. Matching that means
      // the volume can be changed, or a track skipped, without losing the view.
      Keys.onPressed: event => {
        const navigation = [Qt.Key_Escape, Qt.Key_Return, Qt.Key_Enter,
                            Qt.Key_Space, Qt.Key_Backspace, Qt.Key_Tab]
        const printable = event.text.length > 0 && event.text.charCodeAt(0) >= 0x20
        if (printable || navigation.indexOf(event.key) !== -1)
          root.dismiss()
        else
          event.accepted = false
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        property real originX: -1
        property real originY: -1
        onClicked: root.dismiss()
        onPositionChanged: mouse => {
          // A resting hand twitches; only a real move should dismiss.
          if (originX < 0) {
            originX = mouse.x
            originY = mouse.y
            return
          }
          if (Math.abs(mouse.x - originX) > 40 || Math.abs(mouse.y - originY) > 40)
            root.dismiss()
        }
        onVisibleChanged: { originX = -1; originY = -1 }
      }

      Column {
        id: content
        anchors.centerIn: parent
        spacing: Style.space(48)

        Item {
          anchors.horizontalCenter: parent.horizontalCenter
          width: artCurrent.implicitWidth
          height: artCurrent.implicitHeight
          opacity: root.artHtml !== "" ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 250 } }

          // A track change swapping one block of text for another lands as a
          // jump cut. Two layers, with the new one brought up over the old,
          // makes it a dissolve instead.
          Text {
            id: artCurrent
            text: root.artHtml
            opacity: 1
            textFormat: Text.RichText
            font.family: Style.fontFamily
            font.pixelSize: 15
            lineHeight: 0.78
            horizontalAlignment: Text.AlignHCenter
          }

        }

        // The spectrum: two blocks of monospace text used as masks over a
        // gradient built from the theme's palette. Bass on the left, treble on
        // the right, and the lower half kept dim so it reads as a reflection.
        Column {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: 0

          Component.onCompleted: {}

          Item {
            width: upperText.implicitWidth
            height: upperText.implicitHeight

            Text {
              id: upperText
              text: root.frame.upper
              font.family: Style.fontFamily
              font.pixelSize: 20
              lineHeight: 0.92
              // Centring each line on its own shears the spectrum: Qt measures a
              // line without its trailing spaces, so quiet columns on the right
              // make that line shorter and it drifts. Align left; the block as a
              // whole is centred by its parent.
              horizontalAlignment: Text.AlignLeft
              visible: false
              layer.enabled: true
            }

            Rectangle {
              id: upperPaint
              anchors.fill: parent
              visible: false
              layer.enabled: true
              gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.00; color: root.paletteAt(0) }
                GradientStop { position: 0.25; color: root.paletteAt(1) }
                GradientStop { position: 0.50; color: root.paletteAt(2) }
                GradientStop { position: 0.75; color: root.paletteAt(3) }
                GradientStop { position: 1.00; color: root.paletteAt(4) }
              }
            }

            OpacityMask {
              anchors.fill: parent
              source: upperPaint
              maskSource: upperText
            }
          }

          Item {
            width: lowerText.implicitWidth
            height: lowerText.implicitHeight
            opacity: 0.38

            Text {
              id: lowerText
              text: root.frame.lower
              font.family: Style.fontFamily
              font.pixelSize: 20
              lineHeight: 0.92
              horizontalAlignment: Text.AlignLeft
              visible: false
              layer.enabled: true
            }

            OpacityMask {
              anchors.fill: parent
              source: upperPaint
              maskSource: lowerText
            }
          }
        }

        Column {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(8)

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.scrambled(root.heldTitle)
            color: Color.foreground
            font.family: Style.fontFamily
            font.pixelSize: 20
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.scrambled(root.heldArtist)
            color: Color.muted
            font.family: Style.fontFamily
            font.pixelSize: 16
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            opacity: root.trackLength > 0 ? 1 : 0
            spacing: Style.space(12)
            Behavior on opacity { NumberAnimation { duration: 200 } }

            Text {
              text: root.clock(root.trackPosition)
              color: Color.muted
              font.family: Style.fontFamily
              font.pixelSize: 14
            }
            Text {
              text: root.progressLine(48)
              color: Color.accent
              font.family: Style.fontFamily
              font.pixelSize: 14
            }
            Text {
              text: root.clock(root.trackLength)
              color: Color.muted
              font.family: Style.fontFamily
              font.pixelSize: 14
            }
          }
        }
      }
    }
  }
}