// The Mac's sound for the VM's audio panel (OmacVMSound), without Control
// Center:
//   cd app/app && swift run sound-tests
// Exit 0 when all pass. CI runs it on every pull request.
import Foundation
import OmacVMSound

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) (line \(line))"); failures += 1 }
}

// Control Center's Sound list on a Mac with a Studio Display and a HomePod
// called Kitchen, as `OmacVM --sound tree` printed it (macOS 27.2.1; the
// device names are placeholders). The titles follow the Mac's language, the
// identifiers do not.
func list(display: String, kitchen: String, builtIn: String = "0") -> [SoundElement] {
    [SoundElement(depth: 0, role: "AXWindow", subrole: "AXSystemDialog"),
     SoundElement(depth: 1, role: "AXGroup", subrole: "AXHostingView"),
     SoundElement(depth: 2, role: "AXStaticText", identifier: "controlcenter-volume", value: "Sound"),
     SoundElement(depth: 2, role: "AXButton", description: "Volume Lower"),
     SoundElement(depth: 2, role: "AXSlider", identifier: "controlcenter-volume-slider", description: "sound volume", value: "0.3038005828857422"),
     SoundElement(depth: 3, role: "AXValueIndicator"),
     SoundElement(depth: 2, role: "AXButton", description: "Volume Higher"),
     SoundElement(depth: 2, role: "AXScrollArea"),
     SoundElement(depth: 3, role: "AXHeading", description: "Output"),
     SoundElement(depth: 3, role: "AXCheckBox", subrole: "AXToggle", identifier: "sound-device-MacBook Pro Speakers", description: "MacBook Pro Speakers", value: builtIn),
     SoundElement(depth: 3, role: "AXCheckBox", subrole: "AXToggle", identifier: "sound-device-Studio Display Speakers", description: "Studio Display Speakers", value: display),
     SoundElement(depth: 3, role: "AXCheckBox", subrole: "AXToggle", identifier: "sound-device-Kitchen", description: "Kitchen", value: kitchen),
     SoundElement(depth: 2, role: "AXButton", description: "Sound Settings…")]
}

let onDisplay = SoundList.rows(list(display: "1", kitchen: "0"))
expect(onDisplay == [SoundRow(name: "MacBook Pro Speakers", selected: false), SoundRow(name: "Studio Display Speakers", selected: true),
                     SoundRow(name: "Kitchen", selected: false)],
       "the list on the display's speakers: three devices in Control Center's order, the display's with the checkmark")
expect(SoundList.rows([SoundElement(depth: 0, role: "AXCheckBox", identifier: "controlcenter-airplay", value: "0"),
                       SoundElement(depth: 0, role: "AXCheckBox", identifier: "sound-device-", value: "1"),
                       SoundElement(depth: 0, role: "AXButton", identifier: "sound-device-Kitchen")]).isEmpty,
       "the Sound module's own button, a row without a name and a button are no devices")

// The same Mac with AirPods Pro as its output, as Accessibility gave it
// (macOS 27.2.1): everything of the AirPods has their identifier. A
// disclosure triangle before their row (1: open), the row, whose description
// also has the battery, then per group of modes a heading and its options.
// "Not Available" is not enabled.
let airPods = "sound-device-AirPods Pro"
func airPodsList(listening: String = "Transparency", notAvailable: String = "0", open: Bool = true, playing: String = "1") -> [SoundElement] {
    func option(_ title: String, _ value: String, enabled: Bool = true) -> SoundElement {
        SoundElement(depth: 3, role: "AXCheckBox", subrole: "AXToggle", identifier: airPods, description: title, value: value, enabled: enabled)
    }
    func heading(_ title: String) -> SoundElement { SoundElement(depth: 3, role: "AXHeading", identifier: airPods, description: title) }
    func device(_ name: String) -> SoundElement {
        SoundElement(depth: 3, role: "AXCheckBox", subrole: "AXToggle", identifier: "sound-device-" + name, description: name, value: "0")
    }
    // With Adaptive selected, its level control: three images between the options.
    let level = listening != "Adaptive" ? [] : ["Dotted Circle", "Person And Sparkles, Filled", "Circle"].map {
        SoundElement(depth: 3, role: "AXImage", identifier: airPods, description: $0)
    }
    let modes = [heading("Listening Mode"), option("Transparency", listening == "Transparency" ? "1" : "0"),
                 option("Adaptive", listening == "Adaptive" ? "1" : "0")] + level
        + [option("Noise Cancellation", listening == "Noise Cancellation" ? "1" : "0"),
           heading("Spatial Audio"), option("Not Available", notAvailable, enabled: false),
           heading("Conversation Awareness"), option("Off", "1"), option("On", "0")]
    return [SoundElement(depth: 0, role: "AXWindow", subrole: "AXSystemDialog"),
            SoundElement(depth: 1, role: "AXGroup", subrole: "AXHostingView"),
            SoundElement(depth: 2, role: "AXStaticText", identifier: "controlcenter-volume", value: "Sound"),
            SoundElement(depth: 2, role: "AXSlider", identifier: "controlcenter-volume-slider", description: "sound volume", value: "0.5"),
            SoundElement(depth: 3, role: "AXValueIndicator"),
            SoundElement(depth: 2, role: "AXSlider", identifier: "controlcenter-volume-slider", description: "sound volume", value: "0.5"),
            SoundElement(depth: 2, role: "AXScrollArea"),
            SoundElement(depth: 3, role: "AXHeading", description: "Output"),
            device("MacBook Pro Speakers"), device("Studio Display Speakers"),
            SoundElement(depth: 3, role: "AXDisclosureTriangle", identifier: airPods, description: open ? "Go Down" : "Forward", value: open ? "1" : "0"),
            SoundElement(depth: 3, role: "AXCheckBox", subrole: "AXToggle", identifier: airPods, description: "AirPods Pro, 100%, 90%", value: playing)]
        + (open ? modes : [])
        + [device("Kitchen"),
           SoundElement(depth: 2, role: "AXButton", description: "AirPods Pro Settings…"),
           SoundElement(depth: 2, role: "AXButton", description: "Sound Settings…")]
}
func listening(_ selected: String) -> SoundMode {
    SoundMode(title: "Listening Mode", options: ["Transparency", "Adaptive", "Noise Cancellation"].map { SoundOption(title: $0, selected: $0 == selected) })
}
let conversation = SoundMode(title: "Conversation Awareness", options: [SoundOption(title: "Off", selected: true), SoundOption(title: "On", selected: false)])
let pods = "AirPods Pro"
let withAirPods = airPodsList()
expect(SoundList.rows(withAirPods) == [
    SoundRow(name: "MacBook Pro Speakers", selected: false), SoundRow(name: "Studio Display Speakers", selected: false),
    SoundRow(name: pods, selected: true, modes: [
        listening("Transparency"),
        SoundMode(title: "Spatial Audio", options: [SoundOption(title: "Not Available", selected: false, enabled: false)]),
        conversation]),
    SoundRow(name: "Kitchen", selected: false)],
       "AirPods with their modes open: one device, by its identifier, with macOS's three groups in its words, and none for a mode")
let afterAdaptive = airPodsList(listening: "Adaptive", notAvailable: "1")
expect(SoundList.rows(afterAdaptive).first { $0.name == pods }?.modes == [
    listening("Adaptive"),
    SoundMode(title: "Spatial Audio", options: [SoundOption(title: "Not Available", selected: true, enabled: false)]),
    conversation],
       "after a press of Adaptive: Adaptive selected, its level's images are no options, and a Not Available that is selected stays not enabled")
let closed = airPodsList(open: false)
expect(SoundList.rows(closed).first { $0.name == pods } == SoundRow(name: pods, selected: true), "the disclosure closed: the AirPods without modes")
expect(SoundList.closedDisclosure(closed).map { closed[$0].role } == "AXDisclosureTriangle" && SoundList.closedDisclosure(withAirPods) == nil,
       "the AirPods play and their disclosure is closed: it is opened before a read; open: left alone")
expect(SoundList.closedDisclosure(airPodsList(open: false, playing: "0")) == nil, "the closed disclosure of a device that does not play: left alone")

// `OmacVM --sound tree` prints what Control Center shows (SoundWindow.shown),
// played here through a window of recorded lists. A press of the disclosure
// opens the AirPods' modes, as Control Center does.
final class Recorded: SoundWindow {
    var shows: [SoundElement]
    let afterPress: [SoundElement]
    init(_ shows: [SoundElement], afterPress: [SoundElement] = []) { self.shows = shows; self.afterPress = afterPress }
    func read() -> [SoundElement] { shows }
    func press(_ find: ([SoundElement]) -> Int?) throws {
        guard find(shows) != nil else { throw SoundPicker.Failure.interrupted }
        shows = afterPress
    }
}
expect((try? Recorded(closed, afterPress: withAirPods).shown()) == withAirPods,
       "the tree of a list this code reads: the list as a read gives it, with the AirPods' modes opened")
// A macOS whose devices are radio buttons, not checkboxes (3 s: a read's wait for a list).
let radios = list(display: "1", kitchen: "0").map { e -> SoundElement in
    var e = e
    if e.identifier.hasPrefix("sound-device-") { e.role = "AXRadioButton" }
    return e
}
expect(!SoundList.isList(radios) && (try? Recorded(radios).shown()) == radios,
       "the tree of a list this code cannot read (its devices are radio buttons): the window as it is, not \"no list\"")

let rowsNow = SoundList.rows(withAirPods)
expect(SoundList.option(rowsNow, device: pods, group: "Conversation Awareness", option: "On") == SoundOption(title: "On", selected: false)
       && SoundList.option(rowsNow, device: pods, group: "Listening Mode", option: "On") == nil,
       "an option by its group: On of Conversation Awareness, and no On under Listening Mode")
expect(SoundList.option(rowsNow, device: pods, group: "Spatial Audio", option: "Not Available")?.enabled == false,
       "Spatial Audio's Not Available: there, and not offered")
expect(SoundList.optionIndex(withAirPods, device: pods, group: "Listening Mode", option: "Adaptive").map { withAirPods[$0].description } == "Adaptive"
       && SoundList.optionIndex(afterAdaptive, device: pods, group: "Listening Mode", option: "Noise Cancellation").map { afterAdaptive[$0].description } == "Noise Cancellation",
       "the option to press, found again in the list rebuilt after a press (with the level's images in it)")
expect(SoundList.optionIndex(withAirPods, device: pods, group: "Listening Mode", option: "AirPods Pro, 100%, 90%") == nil
       && SoundList.optionIndex(withAirPods, device: "Kitchen", group: "Listening Mode", option: "Adaptive") == nil
       && SoundList.optionIndex(closed, device: pods, group: "Listening Mode", option: "Adaptive") == nil,
       "never the device's own row, never another device's, and nothing while the modes are closed")
expect(SoundList.isList(withAirPods) && !SoundList.isList([SoundElement(depth: 0, role: "")]) && !SoundList.isList(Array(withAirPods.prefix(7))),
       "a window that answers nothing, or a list being rebuilt without devices, is no list")

// A press of Kitchen on the HomePod, as Control Center's list moved
// (2026-11-20): the display's checkmark went after 16 ms, the HomePod's came
// after 420 ms, when it was connected.
let connecting = SoundList.rows(list(display: "0", kitchen: "0"))
let onHomePod = SoundList.rows(list(display: "0", kitchen: "1"))
expect(!SoundList.pressDone("Kitchen", before: onDisplay, now: onDisplay, moved: false), "right after the press: not done")
expect(!SoundList.pressDone("Kitchen", before: onDisplay, now: connecting, moved: true), "while macOS connects (no checkmark anywhere): not done")
expect(SoundList.pressDone("Kitchen", before: onDisplay, now: onHomePod, moved: true), "the HomePod has the checkmark: done")
expect(SoundList.switched("Kitchen", before: onDisplay, now: onHomePod) && !SoundList.switched("Kitchen", before: onDisplay, now: onDisplay),
       "the press took effect only when the HomePod's checkmark changed: macOS going back is a failure, not a switch")
expect(SoundList.pressDone("Kitchen", before: onDisplay, now: onDisplay, moved: true),
       "the speaker did not connect and the display has its checkmark again: done")
expect(SoundList.pressDone("Kitchen", before: onHomePod, now: connecting, moved: true), "a press of the playing HomePod takes its checkmark: done")
expect(!SoundList.pressDone("Kitchen", before: onDisplay, now: SoundList.rows(list(display: "0", kitchen: "0")).dropLast(), moved: true),
       "the row is gone for a moment: not done")
expect(SoundList.playing(onDisplay.dropLast()) == SoundList.playing(onDisplay),
       "a row without a checkmark that one read misses moves nothing")

// The route's rules.
func body(_ s: String) -> Data { Data(s.utf8) }
func parse(_ method: String, _ b: String? = nil) -> Result<SoundGuest.Request, SoundGuest.Refusal> {
    SoundGuest.parse(method: method, body: b.map(body))
}
expect(parse("GET") == .success(.state), "GET: the state")
expect(parse("GET", "{}") == .failure(.init(400, "bad-request")), "GET with a body: refused")
expect(parse("POST", #"{"read": true}"#) == .success(.read), "POST read")
expect(parse("POST", #"{"read": false}"#) == .failure(.init(400, "bad-request")), "read: false is nothing to do")
expect(parse("POST", #"{"read": 1}"#) == .failure(.init(400, "bad-request")), "read: 1 is a number, not true")
expect(parse("POST", #"{"press": "Kitchen"}"#) == .success(.press("Kitchen")), "POST press with a device's name")
expect(parse("POST", #"{"press": ""}"#) == .failure(.init(400, "bad-request")), "press: no name")
expect(parse("POST", #"{"press": "a\nb"}"#) == .failure(.init(400, "bad-request")), "press: a name with a line break")
expect(parse("POST", "{\"press\": \"\(String(repeating: "a", count: 256))\"}") == .failure(.init(400, "bad-request")), "press: a name of 256 characters")
let mode = #"{"mode": {"device": "AirPods Pro", "group": "Listening Mode", "option": "Adaptive"}}"#
expect(parse("POST", mode) == .success(.mode(device: pods, group: "Listening Mode", option: "Adaptive")), "POST mode: a device, a group and an option")
for bad in [#"{"mode": {"device": "AirPods", "group": "Listening Mode"}}"#,
            #"{"mode": {"device": "AirPods", "group": "Listening Mode", "option": "Adaptive", "level": 1}}"#,
            #"{"mode": {"device": "AirPods", "group": "Listening Mode", "option": ""}}"#,
            #"{"mode": {"device": "AirPods", "group": "Listening\nMode", "option": "Adaptive"}}"#,
            #"{"mode": {"device": "AirPods", "group": "Listening Mode", "option": 2}}"#,
            #"{"mode": ["AirPods", "Listening Mode", "Adaptive"]}"#] {
    expect(parse("POST", bad) == .failure(.init(400, "bad-request")), "mode refused: \(bad)")
}
let balance = #"{"balance": {"value": 0.25, "output": "display-speakers-uid"}}"#
expect(parse("POST", balance) == .success(.balance(0.25, output: "display-speakers-uid")), "POST balance, of the output the panel showed it for")
expect(parse("POST", #"{"balance": 0.25}"#) == .failure(.init(400, "bad-request")), "balance: without its output, refused")
expect(parse("POST", #"{"allow": true}"#) == .success(.allow), "POST allow")
expect(parse("POST", #"{"allow": "yes"}"#) == .failure(.init(400, "bad-request")), "allow: only true")
expect(parse("POST", #"{"balance": {"value": 1.5, "output": "display-speakers-uid"}}"#) == .failure(.init(400, "bad-request")), "balance: outside 0...1")
expect(parse("POST", #"{"balance": {"value": true, "output": "display-speakers-uid"}}"#) == .failure(.init(400, "bad-request")), "balance: true is no number")
expect(parse("POST", #"{"read": true, "press": "Kitchen"}"#) == .failure(.init(400, "bad-request")), "two keys: refused")
expect(parse("POST", #"["read"]"#) == .failure(.init(400, "bad-request")), "a body that is no object: refused")
expect(parse("POST") == .failure(.init(400, "bad-request")), "POST without a body: refused")

// A VM in the background: the state, and nothing that opens Control Center or
// changes the Mac's sound. Asked only when it matters, so not for a GET.
let service = SoundService { _ in }
var asked = 0
func background(_ method: String, _ b: String? = nil) -> (Int, String) {
    let (status, answer) = service.answer(method: method, body: b.map(body)) { asked += 1; return false }
    return (status, answer["code"] as? String ?? "")
}
expect(background("GET").0 == 200 && asked == 0, "GET: the state, also for a VM in the background, without asking who is in front")
expect(background("POST", #"{"read": true}"#) == (409, "not-front"), "a VM in the background cannot read the list")
expect(background("POST", #"{"press": "Kitchen"}"#) == (409, "not-front"), "nor press a device")
expect(background("POST", mode) == (409, "not-front"), "nor switch a mode")
expect(background("POST", balance) == (409, "not-front"), "nor set the balance")
expect(background("POST", #"{"allow": true}"#) == (409, "not-front"), "nor open the Mac's settings")
expect(background("POST", #"{"nonsense": 1}"#) == (400, "bad-request"), "a bad request is a bad request, in front or not")
expect(parse("PUT") == .failure(.init(405, "method")), "another method: refused")

// The answers.
let none = SoundGuest.state(accessibility: false, output: nil, balance: nil)
expect(none["accessibility"] as? Bool == false && none["output"] is NSNull && none["balance"] is NSNull,
       "no Accessibility, no output, no balance: false, null and null")
let some = SoundGuest.state(accessibility: true, output: "BuiltInSpeakerDevice", balance: (value: 0.5629999, settable: true))
expect(some["output"] as? String == "BuiltInSpeakerDevice", "the output's CoreAudio UID")
expect((some["balance"] as? [String: Any])?["value"] as? NSNumber == NSDecimalNumber(string: "0.563")
       && (some["balance"] as? [String: Any])?["settable"] as? Bool == true, "the balance, rounded to three places")
expect(String(decoding: try! JSONSerialization.data(withJSONObject: SoundGuest.devices(onHomePod.suffix(1)), options: [.sortedKeys]), as: UTF8.self)
       == #"[{"name":"Kitchen","selected":true}]"#, "a device in the answer: its name and its checkmark, and no modes without them")
expect(String(decoding: try! JSONSerialization.data(withJSONObject: SoundGuest.devices(Array(SoundList.rows(withAirPods)[2...2])), options: [.sortedKeys]), as: UTF8.self)
       == #"[{"modes":[{"options":[{"enabled":true,"selected":true,"title":"Transparency"},{"enabled":true,"selected":false,"title":"Adaptive"},"#
        + #"{"enabled":true,"selected":false,"title":"Noise Cancellation"}],"title":"Listening Mode"},"#
        + #"{"options":[{"enabled":false,"selected":false,"title":"Not Available"}],"title":"Spatial Audio"},"#
        + #"{"options":[{"enabled":true,"selected":true,"title":"Off"},{"enabled":true,"selected":false,"title":"On"}],"title":"Conversation Awareness"}],"#
        + #""name":"AirPods Pro","selected":true}]"#,
       "the AirPods in the answer: their modes as macOS's groups, each option with its checkmark and whether it is offered")
for (failure, code) in [(SoundPicker.Failure.notTrusted, "accessibility"), (.open, "busy"), (.unsupported("why"), "unsupported"),
                        (.noDevice("Kitchen"), "no-device"), (.noOption, "no-option"), (.interrupted, "interrupted"),
                        (.notFront, "not-front"), (.unchanged, "unchanged")] {
    let r = SoundGuest.refusal(failure)
    expect(r.code == code && SoundGuest.error(code) != SoundGuest.error("method"), "\(failure): \(r.status) \(code), with a text of its own")
}
for code in ["bad-request", "not-front", "no-balance"] {
    expect(SoundGuest.error(code) != SoundGuest.error("method"), "\(code): a text of its own")
}

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")
