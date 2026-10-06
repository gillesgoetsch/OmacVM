import Foundation

// Offline tests for picking the guest the strip serves (GuestPicker.swift)
// and the handshake on 127.0.0.1 (GuestAuth.swift).
// Run: ./mac/test.sh

var failures = 0
func check<T: Equatable>(_ got: T, _ want: T, _ what: String, line: Int = #line) {
    if got != want {
        failures += 1
        print("FAIL line \(line): \(what): got \(got), want \(want)")
    }
}

let P = "Parallels Desktop", U = "UTM", F = "VMware Fusion", O = "OmacVM"
func g(_ id: Int, _ owner: String?) -> GuestCandidate { GuestCandidate(id: id, owner: owner) }
func pick(_ guests: [GuestCandidate], _ owner: String, current: Int?) -> Int? {
    GuestPicker.pick(guests, owner: owner, current: current)
}

// hello and vmname
check(GuestPicker.owner(hello: "parallels"), P, "hello parallels")
check(GuestPicker.owner(hello: "qemu"), U, "hello qemu")
check(GuestPicker.owner(hello: "vmware"), F, "hello vmware")
check(GuestPicker.owner(hello: "apple"), nil, "hello apple")
check(GuestPicker.owner(hello: "unknown"), nil, "hello unknown")
check(GuestPicker.owner(hello: "parallels more words"), P, "hello with more words")
check(GuestPicker.vmName(base64: "T21hcmNoeQ=="), "Omarchy", "vmname")
check(GuestPicker.vmName(base64: Data("OmacVM 2 Parallels".utf8).base64EncodedString()), "OmacVM 2 Parallels", "vmname with spaces")
check(GuestPicker.vmName(base64: Data("Büro – Omarchy".utf8).base64EncodedString()), "Büro – Omarchy", "vmname UTF-8")
check(GuestPicker.vmName(base64: ""), nil, "empty vmname")
check(GuestPicker.vmName(base64: "not base64!"), nil, "bad base64")
check(GuestPicker.vmName(base64: Data("a\nb".utf8).base64EncodedString()), nil, "vmname with a newline")
check(GuestPicker.vmName(base64: Data([0xff, 0xfe]).base64EncodedString()), nil, "vmname not UTF-8")
check(GuestPicker.vmName(base64: Data(String(repeating: "x", count: 256).utf8).base64EncodedString()), nil, "vmname too long")

// One guest: it, when it can run in the window's app.
check(pick([g(1, P)], P, current: nil), 1, "one guest")
check(pick([g(1, nil)], U, current: nil), 1, "one old guest (app not said)")
check(pick([g(1, P)], U, current: 1), nil, "a Parallels guest never serves a UTM window")
check(pick([g(1, O)], P, current: nil), nil, "an OmacVM.app guest never serves a Parallels window")

// Guests of different apps: the window's app decides, both ways.
let apps = [g(1, P), g(2, U), g(3, O)]
check(pick(apps, U, current: 1), 2, "UTM window")
check(pick(apps, P, current: 2), 1, "Parallels window")
check(pick(apps, O, current: 1), 3, "OmacVM.app window")
check(pick(apps, F, current: 1), nil, "no guest runs in Fusion")

// Two VMs of one app: the current one stays, else the most recently connected.
let two = [g(1, P), g(2, P)]
check(pick(two, P, current: 1), 1, "keeps the current one")
check(pick(two, P, current: 2), 2, "keeps the other current one")
check(pick(two, P, current: nil), 2, "nothing served yet: most recently connected")
check(pick(two + [g(3, U)], P, current: 3), 2, "back from UTM: most recently connected")

// A guest that said the window's app beats one that said nothing.
check(pick([g(1, nil), g(2, P)], P, current: 1), 2, "unknown app vs the front app")
check(pick([g(1, P), g(2, nil)], P, current: nil), 1, "the front app's guest, though older")
check(pick([g(1, nil), g(2, U)], P, current: 2), 1, "the unknown one is the only fit")
check(pick([g(1, nil), g(2, nil)], P, current: 1), 1, "two old guests: keep the current one")

// ParkState: only the served guest is parked; switching unparks the old one first.
var st = ParkState()
var parkedGuests = Set<Int>()
func apply(_ commands: [(guest: Int, line: String)]) {
    for c in commands {
        if c.line == "park 1" { parkedGuests.insert(c.guest) }
        if c.line == "park 0" { parkedGuests.remove(c.guest) }
    }
}
apply(st.activate(1)); apply(st.setParked(true))
check(parkedGuests, [1], "guest 1 parked")
check(st.setParked(true).count, 0, "parking again sends nothing (the heartbeat does)")
let sw = st.activate(2)
check(sw.map { "\($0.guest) \($0.line)" }, ["1 park 0", "1 cursor 1"], "switch: old guest unparked, cursor back")
apply(sw)
check(parkedGuests, [], "nobody parked between")
apply(st.setParked(true))
check(parkedGuests, [2], "guest 2 parked")
check(st.activate(2).count, 0, "same guest: nothing")
st.reset(2, gone: false)  // new session of guest 2 (it starts unparked)
check(st.parked, false, "new session unparked")
check(st.setParked(true).map { "\($0.guest) \($0.line)" }, ["2 park 1"], "re-parked")
st.reset(2, gone: true)
check(st.active, nil, "gone")
check(st.setParked(true).count, 0, "nobody to park")
var st2 = ParkState()
apply(st2.activate(1))
check(st2.activate(2).count, 0, "switching away from an unparked guest sends nothing")

// A guest that connects while no full-screen window serves it is told at once
// that the strip is hidden (it may have started parked); a served one is not.
var s4 = ParkState()
check(s4.connected(1, served: false).map { "\($0.guest) \($0.line)" }, ["1 park 0"], "windowed: park 0 at once")
apply(s4.activate(1))
check(s4.connected(1, served: true).count, 0, "full screen: nothing until the strip shows")
s4.reset(1, gone: false)
check(s4.connected(1, served: false).map(\.line), ["park 0"], "reconnect while windowed: park 0")

// The whole loop with fake windows: at most one bar parked, always the front VM's.
var s3 = ParkState()
parkedGuests = []
let guests = [g(1, P), g(2, U), g(3, O), g(4, P)]
let windows: [(String, Int?)] = [(P, 4), (U, 2), (O, 3), (P, 4), (F, nil), (U, 2)]
for (owner, want) in windows {
    let p = GuestPicker.pick(guests, owner: owner, current: s3.active)
    check(p, want, "front \(owner)")
    if let p {
        apply(s3.activate(p))
        apply(s3.setParked(true))
    }
    check(parkedGuests.count <= 1, true, "at most one bar parked")
    if let want { check(parkedGuests, [want], "the front VM's bar is parked") }
}

// The handshake's proofs (Python's hmac gives the same).
let tok = Array(String(repeating: "0123456789abcdef", count: 4).utf8)
let gn = "00112233445566778899aabbccddeeff", mn = "ffeeddccbbaa99887766554433221100"
check(GuestAuth.proof(token: tok, who: "mac", addr: "127.0.0.1", guestNonce: gn, macNonce: mn),
      "6fa309bdb8d1e1803b2875f65bb9cf1542cc4d9842c7dc07de5a7f775a954ce6", "Mac's proof")
check(GuestAuth.proof(token: tok, who: "vm", addr: "127.0.0.1", guestNonce: gn, macNonce: mn),
      "48fcac6736d91efc2fbf44882c689c7bfc2f65bb74498f5b7e58026c292e89f2", "VM's proof")
check(GuestAuth.proof(token: tok, who: "mac", addr: "10.211.55.2", guestNonce: gn, macNonce: mn)
      != GuestAuth.proof(token: tok, who: "mac", addr: "127.0.0.1", guestNonce: gn, macNonce: mn), true,
      "the address counts")
check(GuestAuth.nonce().count, 32, "nonce length")
check(GuestAuth.nonce() != GuestAuth.nonce(), true, "fresh nonces")
check(GuestAuth.isHex(Substring(gn), count: 32), true, "hex nonce")
check(GuestAuth.isHex("00112233445566778899AABBCCDDEEFF", count: 32), false, "upper-case hex")
check(GuestAuth.isHex("0011", count: 32), false, "short nonce")
check(GuestAuth.same(Array("abc".utf8), Array("abc".utf8)), true, "same")
check(GuestAuth.same(Array("abc".utf8), Array("abd".utf8)), false, "not same")
check(GuestAuth.same(Array("abc".utf8), Array("ab".utf8)), false, "other length")

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
