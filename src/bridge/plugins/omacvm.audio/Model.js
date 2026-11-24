// Derived from Omarchy's omarchy.audio widget (MIT, see LICENSE). The
// helpers below map omacvm-bridge audio payloads (the Mac's CoreAudio devices)
// onto the native widget's labels and glyphs.

function outputVolumeName(volume, muted) {
  if (muted) return "Muted"
  var p = Math.round(volume * 100)
  if (p === 0) return "Silenced"
  if (p >= 100) return "Concert hall"
  if (p >= 85) return "Party mode"
  if (p >= 70) return "Cranked up"
  if (p >= 50) return "Steady groove"
  if (p >= 30) return "Easy listening"
  if (p >= 15) return "Murmur"
  return "Whisper"
}

function deviceBlob(device) {
  if (!device) return ""
  return String([device.name, device.transport, device.uid].join(" ")).toLowerCase()
}

function isHeadphones(device) {
  var blob = deviceBlob(device)
  return blob.indexOf("headphone") !== -1
    || blob.indexOf("headset") !== -1
    || blob.indexOf("earbud") !== -1
    || blob.indexOf("earphone") !== -1
    || blob.indexOf("airpod") !== -1
    || blob.indexOf("beats") !== -1
}

function sinkGlyph(device) {
  if (!device) return "󰓃"
  if (device.allow) return "󰌾"
  if (device.transport === "airplay") return "󰀟"
  if (isHeadphones(device)) return "󰋋"
  var blob = deviceBlob(device)
  if (blob.indexOf("bluetooth") !== -1) return "󰂯"
  if (blob.indexOf("hdmi") !== -1 || blob.indexOf("displayport") !== -1 || blob.indexOf("display") !== -1 || blob.indexOf("airplay") !== -1) return "󰍹"
  return "󰓃"
}

function sourceGlyph(device) {
  if (!device) return "󰍬"
  var blob = deviceBlob(device)
  if (blob.indexOf("headset") !== -1 || isHeadphones(device)) return "󰋋"
  if (blob.indexOf("bluetooth") !== -1) return "󰂯"
  if (blob.indexOf("webcam") !== -1 || blob.indexOf("camera") !== -1) return "󰄀"
  return "󰍬"
}

function deviceLabel(device) {
  if (!device) return "Unknown"
  return String(device.name || device.uid || "Unknown")
}

// Primitives only: rows become Repeater model data.
function deviceRows(audio, wantOutput) {
  var devices = audio && Array.isArray(audio.devices) ? audio.devices : []
  var rows = []
  for (var i = 0; i < devices.length; i++) {
    var d = devices[i]
    if (!d) continue
    if (wantOutput ? !d.has_output : !d.has_input) continue
    rows.push({
      uid: String(d.uid || ""),
      name: deviceLabel(d),
      transport: String(d.transport || ""),
      active: wantOutput ? !!d.default_output : !!d.default_input
    })
  }
  return rows
}

// The outputs for the panel's list, from three sources: CoreAudio's devices
// (audio, omacvm-bridge), the Mac's paired Bluetooth devices (bluetooth,
// omacvm-bridge) and what macOS's own Sound list offers (sound, `omacvm
// sound`; null: the app has no answer). CoreAudio knows a device only while
// it is connected, so macOS lists more: an AirPlay speaker, and a paired
// headset that is not connected. Those are switched through macOS's list
// (picker: true), the rest by their CoreAudio uid.
//   outputs  CoreAudio's outputs, then the headsets macOS offers
//   airplay  every other device macOS lists: AirPlay speakers and TVs; or,
//            while macOS does not let the app read its list, the one row
//            that opens the Mac's settings for it (allow: true)
// The output that plays has the modes macOS offers for it (modes: macOS's
// groups, such as AirPods' Listening Mode, from a list read for this output),
// matched by name: CoreAudio and macOS's list name AirPods alike. A group
// shows only while macOS offers one of its options: Spatial Audio with only
// "Not Available" would be a line of text nobody can use.
// While AirPlay plays, CoreAudio has one device for it, whatever the
// speakers. The speaker's own row has the checkmark, as on the Mac, and
// CoreAudio's device has no row: not once a speaker's row has the checkmark,
// and not while the list is being read. The checkmarks are the ones macOS's
// list had when it was read (sound.devicesOutput is the default output's uid
// then); with another output since, on AirPlay again, nobody knows which
// speakers play, and CoreAudio's device keeps its row and the checkmark.
function outputLists(audio, bluetooth, sound) {
  var outputs = deviceRows(audio, true)
  if (sound && !sound.accessibility) {
    return { outputs: outputs, airplay: [{ uid: "", name: "Allow Accessibility for OmacVM", transport: "", allow: true, active: false }] }
  }
  var known = {}
  for (var i = 0; i < outputs.length; i++) known[outputs[i].name] = true
  var paired = {}
  var bt = bluetooth && Array.isArray(bluetooth.devices) ? bluetooth.devices : []
  for (var b = 0; b < bt.length; b++) {
    if (bt[b] && bt[b].paired && bt[b].name) paired[String(bt[b].name)] = true
  }
  var output = audio && audio.output ? audio.output : null
  var onAirplay = !!output && output.transport === "airplay"
  var listed = sound && Array.isArray(sound.devices) ? sound.devices : []
  var fresh = !!sound && !!output && sound.devicesOutput === output.uid
  var current = fresh ? outputs.find(function(o) { return o.active }) : null
  var entry = current ? listed.find(function(l) { return l.name === current.name }) : null
  var offered = entry && Array.isArray(entry.modes) ? entry.modes.filter(function(g) { return g.options.some(function(op) { return op.enabled }) }) : []
  // Copies: outputStops numbers them.
  if (offered.length) current.modes = offered.map(function(g) { return { title: g.title, options: g.options } })
  var airplay = []
  var playing = false
  for (var d = 0; d < listed.length; d++) {
    var name = String(listed[d].name || "")
    if (!name || known[name]) continue
    var row = { uid: "", name: name, picker: true }
    if (paired[name]) {
      row.transport = "bluetooth"
      row.active = false
      outputs.push(row)
    } else {
      row.transport = "airplay"
      row.active = onAirplay && fresh && !!listed[d].selected
      playing = playing || row.active
      airplay.push(row)
    }
  }
  if (playing || (sound && sound.reading)) outputs = outputs.filter(function(o) { return o.transport !== "airplay" })
  return { outputs: outputs, airplay: airplay }
}

// The output list's cursor stops in the order they show: each row, under the
// row that plays one stop per group of its modes (h/l walks its options),
// then the AirPlay rows. Each row and group gets its stop's index, for the
// cursor.
function outputStops(outputs, airplay) {
  var stops = []
  var rows = outputs.concat(airplay)
  for (var i = 0; i < rows.length; i++) {
    rows[i].stop = stops.length
    stops.push({ row: rows[i], group: null })
    var modes = rows[i].modes || []
    for (var g = 0; g < modes.length; g++) {
      modes[g].stop = stops.length
      stops.push({ row: rows[i], group: modes[g] })
    }
  }
  return stops
}

// Where a stop of an earlier list is in a new one: the same row, by name, and
// the same group of its modes, by title; -1 once it is gone.
function stopIndex(stops, stop) {
  var group = stop.group ? stop.group.title : null
  for (var i = 0; i < stops.length; i++) {
    if (stops[i].row.name === stop.row.name && (stops[i].group ? stops[i].group.title : null) === group) return i
  }
  return -1
}

// Where the cursor lands in a group: on the option macOS has selected, else
// on the first it offers; delta walks the options it offers from `from`.
function optionCursor(group, from, delta) {
  var options = group ? group.options : []
  var offered = []
  for (var i = 0; i < options.length; i++) if (options[i].enabled) offered.push(i)
  if (!offered.length) return -1
  var at = offered.indexOf(from)
  if (at < 0) {
    for (var s = 0; s < options.length; s++) if (options[s].selected && options[s].enabled) return s
    return offered[0]
  }
  return offered[Math.max(0, Math.min(offered.length - 1, at + (delta || 0)))]
}

// Whether the panel reads macOS's Sound list now, and for which output. A
// read opens Control Center on the Mac for about a second, so the panel
// reads once per opening, and once more when a Bluetooth output plays whose
// modes its list may lack: only a read opens the modes of headphones such as
// AirPods. A press of a row answers with the list as it stands, where macOS
// often keeps those modes closed, and a read on its way may have begun
// before the headphones played.
// asked: the uid of the output this opening last read the list for, "" when
// its list may lack the modes of headphones, or null before the opening's
// first read (listAnswered).
// told: the Mac's output as the app's last answer named it. Past the
// opening's first read, the panel reads only while the Bridge reports that
// output too: until both name it, one of them has not seen the Mac's last
// switch, and a read would be for an output that no longer plays. The one
// that reports it last asks again (Panel.qml asks the app for its state
// while the two name other outputs).
// Answers the uid to read the list for now ("" without an output), or null:
// no read.
function listRead(asked, output, told) {
  var uid = output ? String(output.uid || "") : ""
  if (asked === null) return uid
  return output && output.transport === "bluetooth" && uid !== asked && uid === told ? uid : null
}

// asked for listRead once the app answered a request: "press" when a press
// of a row answered with a list, "list" when a read or a mode did, "" for
// anything else (the state, a failure); told: the Mac's output as the answer
// names it. A press's list may lack the modes of headphones, and so may a
// read's or a mode's when its answer names another output than the one the
// panel last read the list for: the Mac switched meanwhile. A request of the
// last opening leaves this opening's first read to come.
function listAnswered(asked, request, told) {
  if (asked === null) return null
  return request === "press" || (request === "list" && told !== asked) ? "" : asked
}

// Why a read or a press of macOS's Sound list did not work, by the app's code.
function soundFailureText(code) {
  if (code === "busy") return "Close Control Center and try again"
  if (code === "no-device") return "That speaker is no longer available"
  if (code === "no-option") return "That mode isn't available right now"
  if (code === "unchanged") return "The Mac didn't switch, try again"
  if (code === "interrupted") return "A click interrupted us, try again"
  return "We couldn't read the Mac's speakers"
}

function clamp01(v) {
  var n = Number(v)
  if (!isFinite(n)) return 0
  return Math.max(0, Math.min(1, n))
}

if (typeof module !== "undefined") {
  module.exports = {
    outputVolumeName: outputVolumeName,
    isHeadphones: isHeadphones,
    sinkGlyph: sinkGlyph,
    sourceGlyph: sourceGlyph,
    deviceLabel: deviceLabel,
    deviceRows: deviceRows,
    outputLists: outputLists,
    outputStops: outputStops,
    stopIndex: stopIndex,
    optionCursor: optionCursor,
    listRead: listRead,
    listAnswered: listAnswered,
    soundFailureText: soundFailureText,
    clamp01: clamp01
  }
}
