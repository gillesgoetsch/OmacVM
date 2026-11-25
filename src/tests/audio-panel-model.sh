#!/bin/bash
# The audio panel's output list (src/bridge/plugins/omacvm.audio/Model.js):
# which of the outputs macOS lists are AirPlay speakers, which row has the
# checkmark, which row has the modes of headphones, where the cursor stops,
# and when the panel reads macOS's Sound list (also on random orders of
# events; OMACVM_SEED=N replays a run). On the payloads of a Mac with a
# Studio Display, a HomePod called Kitchen and AirPods Pro (placeholder
# names).
#   src/tests/audio-panel-model.sh
set -euo pipefail
cd "$(dirname "$0")/../bridge/plugins/omacvm.audio"
node - <<'JS'
const M = require("./Model.js")
let failed = 0
function expect(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what); if (!ok) failed++ }
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)

const display = { uid: "display-speakers-uid", name: "Studio Display Speakers", transport: "usb", has_output: true, has_input: false, default_output: true, default_input: false }
const mic = { uid: "display-microphone-uid", name: "Studio Display Microphone", transport: "usb", has_output: false, has_input: true, default_output: false, default_input: true }
const builtIn = { uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", transport: "built-in", has_output: true, has_input: false, default_output: false, default_input: false }
const airplayDevice = { uid: "airplay-session-1-uid", name: "AirPlay", transport: "airplay", has_output: true, has_input: false, default_output: true, default_input: false }
const onDisplay = { output: display, devices: [display, mic, builtIn] }
const onAirplay = { output: airplayDevice, devices: [airplayDevice, Object.assign({}, display, { default_output: false }), mic, builtIn] }
const bluetooth = { devices: [{ name: "Apple Watch", paired: true, connected: false }, { name: "Headset", paired: true, connected: false }] }
const listed = (selected, output) => ({ accessibility: true, devicesOutput: output, devices: [
  { name: "MacBook Pro Speakers", selected: false }, { name: "Studio Display Speakers", selected: selected === "display" },
  { name: "Kitchen", selected: selected === "living" }] })
const names = rows => rows.map(r => r.name + (r.active ? "*" : ""))

let l = M.outputLists(onDisplay, bluetooth, null)
expect(same(names(l.outputs), ["Studio Display Speakers*", "MacBook Pro Speakers"]) && l.airplay.length === 0,
  "an app without the list (an older one): CoreAudio's outputs alone, as before")
expect(same(names(M.outputLists(onAirplay, bluetooth, null).outputs), ["AirPlay*", "Studio Display Speakers", "MacBook Pro Speakers"]),
  "on AirPlay with such an app: CoreAudio's AirPlay row stays, as before")

l = M.outputLists(onAirplay, bluetooth, { accessibility: false, devices: null, devicesOutput: "" })
expect(same(names(l.outputs), ["AirPlay*", "Studio Display Speakers", "MacBook Pro Speakers"]) && l.airplay.length === 1 && l.airplay[0].allow === true && !l.airplay[0].picker,
  "macOS does not let the app read its list: one row that opens the Mac's settings, and CoreAudio's AirPlay row")

l = M.outputLists(onDisplay, bluetooth, listed("display", display.uid))
expect(same(names(l.outputs), ["Studio Display Speakers*", "MacBook Pro Speakers"]), "the Mac's own outputs are listed once, from CoreAudio")
expect(same(names(l.airplay), ["Kitchen"]) && l.airplay[0].picker && l.airplay[0].transport === "airplay",
  "the HomePod, which CoreAudio does not know, is an AirPlay row, switched through macOS's list")

l = M.outputLists(onAirplay, bluetooth, listed("living", airplayDevice.uid))
expect(same(names(l.outputs), ["Studio Display Speakers", "MacBook Pro Speakers"]) && same(names(l.airplay), ["Kitchen*"]),
  "on AirPlay: the HomePod's own row has the checkmark, and CoreAudio's AirPlay device has no row")

l = M.outputLists(onDisplay, bluetooth, listed("living", airplayDevice.uid))
expect(same(names(l.airplay), ["Kitchen"]), "back on the display's speakers: no AirPlay checkmark, without asking the Mac")

const stale = listed("living", "airplay-session-2-uid")
l = M.outputLists(onAirplay, bluetooth, stale)
expect(same(names(l.airplay), ["Kitchen"]) && same(names(l.outputs), ["AirPlay*", "Studio Display Speakers", "MacBook Pro Speakers"]),
  "on AirPlay again since the list was read: nobody knows which speaker plays, so CoreAudio's AirPlay row has the checkmark")
l = M.outputLists(onAirplay, bluetooth, Object.assign({ reading: true }, stale))
expect(same(names(l.airplay), ["Kitchen"]) && same(names(l.outputs), ["Studio Display Speakers", "MacBook Pro Speakers"]),
  "while the list is being read: no AirPlay row that the speaker's own row would replace a second later")

const withHeadset = listed("display", display.uid)
withHeadset.devices.push({ name: "Headset", selected: false })
l = M.outputLists(onDisplay, bluetooth, withHeadset)
expect(same(names(l.outputs), ["Studio Display Speakers*", "MacBook Pro Speakers", "Headset"]) && l.outputs[2].picker && same(names(l.airplay), ["Kitchen"]),
  "a paired headset that is not connected is an output, not an AirPlay speaker")
// AirPods Pro as the output: CoreAudio and macOS's list name them alike, and the list has their modes.
const pods = { uid: "airpods-uid", name: "AirPods Pro", transport: "bluetooth", has_output: true, has_input: false, default_output: true, default_input: false }
const onPods = { output: pods, devices: [pods, Object.assign({}, display, { default_output: false }), mic, builtIn] }
const option = (title, selected, enabled) => ({ title: title, selected: selected, enabled: enabled !== false })
const modes = [{ title: "Listening Mode", options: [option("Transparency", true), option("Adaptive", false), option("Noise Cancellation", false)] },
  { title: "Spatial Audio", options: [option("Not Available", true, false)] },
  { title: "Conversation Awareness", options: [option("Off", true), option("On", false)] }]
const podsListed = (output, selected) => ({ accessibility: true, devicesOutput: output, devices: [
  { name: "MacBook Pro Speakers", selected: false }, { name: "Studio Display Speakers", selected: !selected },
  { name: "AirPods Pro", selected: selected, modes: modes }, { name: "Kitchen", selected: false }] })
const groups = rows => rows.map(r => r.name + ":" + (r.modes || []).map(g => g.title).join("/"))

l = M.outputLists(onPods, bluetooth, podsListed(pods.uid, true))
expect(same(groups(l.outputs), ["AirPods Pro:Listening Mode/Conversation Awareness", "Studio Display Speakers:", "MacBook Pro Speakers:"])
  && same(names(l.airplay), ["Kitchen"]),
  "the AirPods play: their row, once, has macOS's groups of modes, and no other row has any; Spatial Audio, whose one option macOS does not offer, is not shown")
const noneOffered = podsListed(pods.uid, true)
noneOffered.devices[2] = Object.assign({}, noneOffered.devices[2], { modes: [modes[1]] })
expect(!M.outputLists(onPods, bluetooth, noneOffered).outputs[0].modes, "AirPods with no option offered at all: no modes under their row")
expect(same(groups(M.outputLists(onPods, bluetooth, podsListed("display-speakers-uid", false)).outputs)[0], "AirPods Pro:"),
  "a list read for another output: no modes, as nobody knows them for the AirPods now")
const podsIdle = Object.assign({}, pods, { default_output: false })
l = M.outputLists({ output: display, devices: [podsIdle, display, mic, builtIn] }, bluetooth, podsListed(display.uid, false))
expect(same(groups(l.outputs), ["AirPods Pro:", "Studio Display Speakers:", "MacBook Pro Speakers:"]),
  "the display plays and the AirPods are connected: no modes under any row")

l = M.outputLists(onPods, bluetooth, podsListed(pods.uid, true))
const stops = M.outputStops(l.outputs, l.airplay)
expect(same(stops.map(s => s.row.name + (s.group ? " > " + s.group.title : "")),
  ["AirPods Pro", "AirPods Pro > Listening Mode", "AirPods Pro > Conversation Awareness",
   "Studio Display Speakers", "MacBook Pro Speakers", "Kitchen"]),
  "the cursor: the AirPods' row, a stop per group under it, then the other rows")
expect(same([l.outputs[0].stop, l.outputs[0].modes.map(g => g.stop), l.airplay[0].stop], [0, [1, 2], 5]),
  "each row and group knows its stop")
const kitchenFirst = M.outputStops(M.outputLists(onPods, bluetooth, podsListed(display.uid, false)).outputs, l.airplay)
expect(M.stopIndex(kitchenFirst, kitchenFirst[3]) === 3 && M.stopIndex(stops, kitchenFirst[3]) === 5
  && M.stopIndex(stops, stops[2]) === 2 && M.stopIndex(kitchenFirst, stops[2]) === -1,
  "the cursor on Kitchen stays on Kitchen when a read adds the AirPods' two groups above it, and a group that is gone is gone")
const listening = l.outputs[0].modes[0]
expect(M.optionCursor(listening, -1, 0) === 0 && M.optionCursor(listening, 0, 1) === 1 && M.optionCursor(listening, 2, 1) === 2 && M.optionCursor(listening, 0, -1) === 0,
  "on Listening Mode the cursor lands on Transparency, which macOS selected, and h/l walk the options and stop at the ends")
const someOff = { title: "Spatial Audio", options: [option("Off", false), option("Fixed", true, false), option("Head Tracked", false)] }
expect(M.optionCursor(someOff, -1, 0) === 0 && M.optionCursor(someOff, 0, 1) === 2,
  "an option macOS does not offer is never under the cursor, also when it is selected")
// The panel's reads of macOS's Sound list. Each event below calls Panel.qml's
// askForList as the panel's handlers do (an opening, the Bridge's report of
// the output, the app's answer to a read, a press or its state); it reads
// only while the app is free. The Mac's output (mac) changes first; the
// Bridge reports it later (bridge), and each answer of the app names it
// (told). Each read is logged by what the Mac plays when it begins: what
// Control Center shows it. On the AirPods Pro above, whose modes macOS keeps
// closed until a read opens them.
function panel(output) {
  const p = { mac: output, output: output, told: output.uid, asked: null, job: "", reads: [] }
  // Sound's read and press start only while the app is free.
  const start = job => { if (p.job) return false; p.job = job; return true }
  p.ask = () => {
    const uid = M.listRead(p.asked, p.output, p.told)
    if (uid !== null && start("read")) { p.asked = uid; p.reads.push(p.mac.name) }
  }
  // Panel.qml's onAnswered: the answer names the Mac's output as it is then.
  const answered = request => { p.told = p.mac.uid; p.asked = M.listAnswered(p.asked, request, p.told); p.ask() }
  p.open = () => { p.asked = null; p.ask() }
  // A click on a CoreAudio row, or a press that connected a speaker.
  p.play = o => { p.mac = o }
  p.bridge = () => { p.output = p.mac; p.ask() }
  // The state that Panel.qml asks the app for when the Bridge reports
  // another output than the app named.
  p.state = () => answered("")
  p.press = () => { start("press") }
  p.free = failed => {
    const job = p.job
    p.job = ""
    if (failed) p.ask(); else answered(job === "press" ? "press" : "list")
  }
  return p
}
const reads = p => p.reads.join(", ")
let p = panel(display)
p.open(); p.free(); p.press(); p.play(pods); p.bridge(); p.free()
expect(reads(p) === "Studio Display Speakers, AirPods Pro",
  "a click on the AirPods: the Bridge reports them before the press answers, and the panel reads the list once more for their modes")
p = panel(display)
p.open(); p.free(); p.press(); p.play(pods); p.free(); p.bridge()
expect(reads(p) === "Studio Display Speakers, AirPods Pro",
  "the Bridge reports the AirPods after the press answered: the same read for their modes")
p = panel(display)
p.open(); p.play(pods); p.bridge(); p.free()
expect(reads(p) === "Studio Display Speakers, AirPods Pro",
  "the AirPods begin to play while the opening's read is on its way: one more read once it answered")
p.free(); p.play(display); p.bridge(); p.state(); p.play(pods); p.bridge(); p.state()
expect(p.reads.length === 2, "one read per output: back on the display, then on the AirPods again, the list still has their modes")
p.open(); p.free()
expect(p.reads.length === 3, "the next opening reads once")
p = panel(pods)
p.open(); p.free(); p.press(); p.play(airplayDevice); p.bridge(); p.state(); p.free(); p.play(pods); p.bridge(); p.state(); p.free()
expect(reads(p) === "AirPods Pro, AirPods Pro",
  "from the AirPods to an AirPlay speaker and back through their own row: the speaker's list lacks their modes, so one more read")
p = panel(pods)
p.open(); p.free(); p.press(); p.play(airplayDevice); p.free(); p.bridge(); p.play(pods); p.bridge(); p.state(); p.free()
expect(reads(p) === "AirPods Pro, AirPods Pro",
  "the same, with the press's answer before the Bridge's report of the speaker: no read while it plays, and one more back on the AirPods")
p = panel(pods)
p.open(); p.play(display); p.free(); p.bridge(); p.play(pods); p.bridge(); p.state(); p.free()
expect(reads(p) === "AirPods Pro, AirPods Pro",
  "a click on the display while the opening's read is on its way: that list is the display's, so back on the AirPods one more read")
p = panel(pods)
p.open(); p.free(); p.press(); p.free(true)
expect(reads(p) === "AirPods Pro", "a press that fails while the AirPods play: no read, and the failure's line stays")
p = panel(display)
p.open(); p.play(pods); p.bridge(); p.open(); p.free()
expect(reads(p) === "Studio Display Speakers, AirPods Pro",
  "opened again while the last opening's read is on its way: a read of its own once that one answered")
p = panel(display)
p.open(); p.free(); p.press(); p.open(); p.free()
expect(reads(p) === "Studio Display Speakers, Studio Display Speakers",
  "opened again while the last opening's press is on its way: the press's list leaves this opening's own read to come")
p = panel(display)
p.open(); p.free(); p.bridge(); p.press(); p.free()
expect(reads(p) === "Studio Display Speakers", "the display plays: one read per opening, also after a press of an AirPlay speaker")
// The promise of the panel's reads, on random orders of events: once the
// app is free and the Bridge has reported the Mac's output, the list has the
// modes of the Bluetooth output that plays; each opening reads once; and
// between two reads there is a reason for the second (an opening, a switch
// of the Mac's output to a Bluetooth output, the Bridge's report of one, or a
// press of a row that answered with a list while a Bluetooth output plays),
// so no loop takes the Mac's keyboard over and over. The world around
// Model.listRead and Model.listAnswered, as the panel's handlers call them:
// openings and closings; the state request of an opening before the app is
// known, and the ones Panel.qml makes when the Bridge and an answer of the
// app name other outputs, one at a time and once more when asked meanwhile;
// the Mac's output, which changes by itself, by a click on a CoreAudio
// row (through the Bridge) or by a press of a row of macOS's list (AirPlay, a
// headset that is not connected), which may fail to connect; the Bridge's
// report of the output as it is then, late, skipping changes in between, or
// again with the same output; the app's request, which looks at Control
// Center at some moment, then notes the Mac's output, and answers later, or
// fails (a mode whose device no longer plays fails); and Control Center's
// disclosures, which a read or a mode opens and which stay as a read or the
// person left them. Assumed: nobody closes a disclosure on the Mac while the
// panel is open, and the app's answers arrive in the order it noted the
// output for them.
// Accepted, as the panel then shows no modes, never wrong ones, and the next
// opening reads again: a failed read is not tried again for its output in
// that opening, because a refusal such as "busy" (the person has Control
// Center open) would come back at once, over and over. And a list that
// Control Center showed for another output than the one the read was for and
// its answer names: the Mac's output changed while the app looked at Control
// Center, and changed back before it answered.
// OMACVM_SEED=N replays a run.
const headset = { uid: "headset-uid", name: "Headset", transport: "bluetooth" }
const outputs = [display, builtIn, pods, headset, airplayDevice]
const bt = o => !!o && o.transport === "bluetooth"
function panelWorld(seed) {
  let s = seed >>> 0
  const rnd = () => { s = (s + 0x6D2B79F5) >>> 0; let t = s; t = Math.imul(t ^ t >>> 15, t | 1); t ^= t + Math.imul(t ^ t >>> 7, t | 61); return ((t ^ t >>> 14) >>> 0) / 4294967296 }
  const pick = a => a[Math.floor(rnd() * a.length)]
  const w = { mac: pick(outputs), reported: true, told: "", open: false, opening: 0, openingRead: false, ready: false, stateJob: null,
    stateAgain: false, job: null, noted: 0, asked: null, list: null, readFailed: false, disclosure: {}, reason: false, pressed: false, broke: "" }
  w.output = w.mac
  for (const o of outputs) w.disclosure[o.uid] = bt(o) && rnd() < 0.5
  // The Bridge reports a change of the Mac's output later.
  const play = o => {
    if (o === w.mac) return
    w.mac = o; w.reported = false
    if (bt(o)) w.reason = true
  }
  // Panel.qml's askForList; Sound.qml's run takes one request at a time.
  const ask = () => {
    if (!w.open || !w.ready) return
    const uid = M.listRead(w.asked, w.output, w.told)
    if (uid === null || w.job) return
    if (!w.reason && !(w.pressed && bt(w.output))) w.broke = "a read without a reason"
    w.reason = false; w.pressed = false
    w.job = { kind: "read", for: uid, opening: w.opening }
    w.asked = uid; w.readFailed = false; w.openingRead = true
  }
  // Sound.qml's refresh, and Panel.qml's when the Bridge and the app's last
  // answer name other outputs.
  const refresh = () => { if (w.stateJob) w.stateAgain = true; else w.stateJob = {} }
  const reconcile = () => { if (w.open && w.ready && w.output.uid !== w.told) refresh() }
  // Panel.qml's onAnswered, after Sound.qml took the answer's output.
  const answered = request => { w.asked = M.listAnswered(w.asked, request, w.told); if (request) reconcile(); ask() }
  const look = j => { if (!j.seen) { j.seen = w.mac; if (j.kind === "mode" && j.seen !== j.device) j.refused = true } }
  // The app notes the Mac's output after its look, or once macOS connected
  // a pressed speaker or gave up; the list of a press or a mode is as it is
  // then.
  const sample = j => {
    if (j.told) return
    if (j.kind === "press" && rnd() < 0.8) play(j.target)
    j.told = w.mac; j.noted = ++w.noted
    j.of = j.kind === "read" ? j.seen : w.mac
  }
  const stateSample = s => { if (!s.told) { s.told = w.mac; s.noted = ++w.noted } }
  // An answer waits for the other request's, when the app noted the output
  // for that one first.
  const waits = j => [w.job, w.stateJob].some(o => o && o !== j && o.noted && (!j.noted || o.noted < j.noted))
  const events = {
    open: () => {
      if (w.open) return
      w.open = true; w.opening++; w.openingRead = false; w.reason = true; w.asked = null; w.readFailed = false
      if (w.ready) ask(); else refresh()
    },
    close: () => { w.open = false },
    stateLook: () => { if (w.stateJob) stateSample(w.stateJob) },
    stateAnswer: () => {
      if (!w.stateJob || waits(w.stateJob)) return
      stateSample(w.stateJob)
      w.told = w.stateJob.told.uid
      w.stateJob = null; w.ready = true
      answered("")
      if (w.stateAgain) { w.stateAgain = false; refresh() }
    },
    macSwitch: () => { play(pick(outputs)) },
    bridge: () => {
      if (w.open && w.mac !== w.output && bt(w.mac)) w.reason = true
      w.output = w.mac; w.reported = true
      reconcile()
      ask()
    },
    rowClick: () => { const o = pick([display, builtIn, pods]); if (w.open && o !== w.output) play(o) },
    press: () => {
      if (!w.open || !w.ready || w.job) return
      w.job = { kind: "press", target: pick([headset, airplayDevice]) }
    },
    mode: () => {
      if (w.open && !w.job && bt(w.output) && w.list && w.list.of === w.output && w.list.told === w.output && w.list.modes) w.job = { kind: "mode", device: w.output }
    },
    look: () => { if (w.job && w.job.kind !== "press") look(w.job) },
    sample: () => { if (w.job && (w.job.kind === "press" || w.job.seen)) sample(w.job) },
    connect: () => { if (w.job && w.job.kind === "press") play(w.job.target) },
    answer: () => {
      const j = w.job
      if (!j || waits(j)) return
      if (j.kind !== "press") look(j)
      w.job = null
      if (j.refused || rnd() < 0.15) {
        if (j.kind === "read" && j.opening === w.opening && j.for === w.asked) w.readFailed = true
        answered("")
        refresh()
        return
      }
      sample(j)
      if (j.kind === "read" && bt(j.of)) w.disclosure[j.of.uid] = true
      w.told = j.told.uid
      w.list = { of: j.of, modes: w.disclosure[j.of.uid], told: j.told }
      if (j.kind === "press") w.pressed = true
      answered(j.kind === "press" ? "press" : "list")
    },
  }
  const names = Object.keys(events)
  return { w: w, step: () => { const name = pick(names); events[name](); return name } }
}
function panelRun(seed, steps) {
  const { w, step } = panelWorld(seed)
  const trace = []
  for (let i = 0; i < steps && !w.broke; i++) {
    trace.push(step())
    const o = w.output
    const settled = w.open && w.ready && !w.job && !w.stateJob && w.reported && bt(o)
    // The panel shows the modes of a list that the app named for o too.
    const hasModes = !!w.list && w.list.of === o && w.list.told === o && w.list.modes
    const failed = w.readFailed && w.asked === o.uid
    const awayAndBack = w.asked === o.uid && !!w.list && w.list.told === o && w.list.of !== o
    if (settled && !hasModes && !failed && !awayAndBack) w.broke = "no modes for " + o.name
    if (w.open && w.ready && !w.job && !w.openingRead) w.broke = "an opening without its read"
  }
  return w.broke ? "seed " + seed + ": " + w.broke + " after " + trace.join(" ") : ""
}
const seedText = process.env.OMACVM_SEED
if (seedText !== undefined && !/^[0-9]+$/.test(seedText)) throw new Error("OMACVM_SEED must be a number: " + seedText)
const seed0 = seedText !== undefined ? Number(seedText) : Math.floor(Math.random() * 4294967296)
let broken = ""
for (let r = 0; r < 20000 && !broken; r++) broken = panelRun(seed0 + r, 60)
expect(!broken, "on 20000 random orders of 60 events (seeds " + seed0 + "+): a read in each opening, the modes of the Bluetooth output that plays once the app is free and the Bridge has reported it, and a reason for each read" + (broken ? "; broke at " + broken : ""))
process.exit(failed ? 1 : 0)
JS
echo "audio-panel-model: all passed"
