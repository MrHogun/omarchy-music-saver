import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Mpris
import qs.Commons

// Music Saver: while something is playing, idling into the screensaver should
// show what is playing rather than a terminal animation.
//
// The stock idle service keeps doing its job; this one watches the same idle
// signal and, only when a player reports Playing, puts a fullscreen spectrum on
// the overlay layer. Any key or a deliberate mouse move takes it away again.
Scope {
  id: root

  readonly property int barCount: 32
  readonly property int rowCount: 10
  property var levels: new Array(32).fill(0)
  property var peaks: new Array(32).fill(0)
  property real overallLevel: 0

  // Drawn the way terminal visualisers draw: monospace blocks, a spectrum
  // mirrored about its centre line, and a peak marker per column that falls
  // slowly behind the music -- the trick cli-visualizer calls falloff, and the
  // thing that makes a spectrum read as rhythm rather than noise.
  readonly property var blocks: [" ", "\u2581", "\u2582", "\u2583", "\u2584",
                                 "\u2585", "\u2586", "\u2587", "\u2588"]
  readonly property string peakUp: "\u2594"    // upper one eighth block
  readonly property string peakDown: "\u2581"  // lower one eighth block
  readonly property real peakFall: 0.012

  readonly property int bandCount: 8

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

  function glyphFor(cell) {
    if (cell >= 1)
      return blocks[8]
    if (cell > 0)
      return blocks[Math.max(1, Math.round(cell * 8))]
    return " "
  }

  function render() {
    const lines = []

    // Upper half: row 0 is the top, so it stands for the loudest level.
    for (let row = 0; row < root.rowCount; row++) {
      const fromCentre = root.rowCount - row
      let line = ""
      for (let col = 0; col < root.barCount; col++) {
        const level = (root.levels[col] || 0) * root.rowCount
        const peak = Math.ceil((root.peaks[col] || 0) * root.rowCount)
        const cell = level - (fromCentre - 1)
        let glyph = glyphFor(cell)
        if (glyph === " " && peak === fromCentre)
          glyph = root.peakUp
        line += glyph + " "
      }
      lines.push(line)
    }

    // Lower half: the same columns reflected, so the loud end sits at the edges.
    for (let row = 0; row < root.rowCount; row++) {
      const fromCentre = row + 1
      let line = ""
      for (let col = 0; col < root.barCount; col++) {
        const level = (root.levels[col] || 0) * root.rowCount
        const peak = Math.ceil((root.peaks[col] || 0) * root.rowCount)
        const cell = level - (fromCentre - 1)
        let glyph = glyphFor(cell)
        if (glyph === " " && peak === fromCentre)
          glyph = root.peakDown
        line += glyph + " "
      }
      lines.push(line)
    }

    return lines
  }

  property var frameRows: render()
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
    frameRows = render()
  }
  property bool showing: false

  // Follow the user's own screensaver timing rather than inventing one.
  property int idleSeconds: 150

  readonly property var player: {
    const players = Mpris.players ? Mpris.players.values : []
    for (const p of players) {
      if (p && p.playbackState === MprisPlaybackState.Playing)
        return p
    }
    return null
  }
  readonly property bool musicPlaying: player !== null
  readonly property string title: player ? (player.trackTitle || "") : ""
  readonly property string artist: player ? (player.trackArtist || "") : ""
  readonly property string artUrl: player ? (player.trackArtUrl || "") : ""
  property string artHtml: ""

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

  // A plain rule with a marker on it, in the same block glyphs as everything else.
  function progressLine(width) {
    if (root.trackLength <= 0)
      return ""
    const ratio = Math.max(0, Math.min(1, root.trackPosition / root.trackLength))
    const at = Math.round(ratio * (width - 1))
    let line = ""
    for (let i = 0; i < width; i++)
      line += i === at ? "\u25c6" : "\u2500"
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
    onLoaded: {
      try {
        const parsed = JSON.parse(text())
        const seconds = parsed && parsed.idle ? parsed.idle.screensaver : null
        if (typeof seconds === "number" && seconds > 0)
          root.idleSeconds = seconds
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
      + "/.config/omarchy/plugins/mrhogun.music-saver/bin/art.py", root.artUrl, "72"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.artHtml = text.trim()
    }
  }

  function refreshArt() {
    if (!root.showing || !root.artUrl) {
      root.artHtml = ""
      return
    }
    artRender.running = false
    artRender.running = true
  }

  onArtUrlChanged: refreshArt()
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

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          visible: root.artHtml !== ""
          text: root.artHtml
          textFormat: Text.RichText
          font.family: Style.fontFamily
          font.pixelSize: 15
          lineHeight: 0.78
          horizontalAlignment: Text.AlignHCenter
        }

        // The spectrum, a row at a time. Drawing it as one block of text makes
        // a single flat slab; row by row, each line can carry its own colour and
        // weight, which is what gives the shape any depth.
        Column {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: 0

          Repeater {
            model: root.frameRows

            Row {
              id: spectrumRow
              required property int index
              required property string modelData

              readonly property int half: root.rowCount
              readonly property bool lower: index >= half
              // Distance from the centre line, 0 at the base out to 1 at the tip.
              readonly property real reach: (lower ? index - half + 1 : half - index) / half

              spacing: 0

              // Split each row across the spectrum so colour carries frequency
              // as well as height. One flat colour over the whole field is what
              // made this read as a single slab.
              Repeater {
                model: root.bandCount

                Text {
                  required property int index
                  readonly property int span: Math.ceil(spectrumRow.modelData.length / root.bandCount)
                  readonly property real tone: root.bandCount > 1 ? index / (root.bandCount - 1) : 0

                  text: spectrumRow.modelData.substr(index * span, span)
                  font.family: Style.fontFamily
                  font.pixelSize: 20
                  font.letterSpacing: 1.5
                  lineHeight: 0.92
                  color: root.bandColour(tone, spectrumRow.reach, spectrumRow.lower)
                }
              }
            }
          }
        }

        Column {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(8)

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.scrambled(root.title)
            color: Color.foreground
            font.family: Style.fontFamily
            font.pixelSize: 20
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.scrambled(root.artist)
            color: Color.muted
            font.family: Style.fontFamily
            font.pixelSize: 16
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.trackLength > 0
            spacing: Style.space(12)

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