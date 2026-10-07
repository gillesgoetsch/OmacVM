// When a running VM changes network (OmacVMNet), without a VM or Xcode:
//   cd app/app && swift run net-tests
// Exit 0 when all pass. CI runs it on every pull request.
import Foundation
import OmacVMNet

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) (line \(line))"); failures += 1 }
}

typealias W = FastNetworkWatch

/// Polls with the given answers, each step done as asked (ok), the steps back.
func run(_ w: inout W, _ ups: [Bool?], ok: Bool = true) -> [W.Step] {
    ups.map { up in
        let s = w.poll(up)
        if s != .none { w.finished(s, ok: ok) }
        return s
    }
}
let down = [Bool?](repeating: false, count: W.window)
let back = [Bool?](repeating: true, count: W.window)

// A connected VM stays on vmnet; a daemon restart (one poll) changes nothing.
var w = W()
expect(run(&w, [true, true, false, true, true, true, true]).allSatisfy { $0 == .none }, "one missed poll: no switch")

// The daemon goes: the user network after a full window, once.
w = W()
var s = run(&w, down)
expect(s.last == .toUser && s.dropLast().allSatisfy { $0 == .none }, "daemon gone: user network after \(W.window) polls")
expect(w.onUser && w.userUp, "on the user network, its card up")
expect(run(&w, down).allSatisfy { $0 == .none }, "still gone: nothing more")

// Back: vmnet's card first, the user card only after the handover.
s = run(&w, back)
expect(s.last == .toVmnet && s.dropLast().allSatisfy { $0 == .none }, "daemon back for a whole window: vmnet card up")
expect(!w.onUser && w.userUp, "the user card is still up right after")
s = run(&w, [Bool?](repeating: true, count: W.handover))
expect(s.allSatisfy { $0 == .none }, "both cards up for \(W.handover) polls")
expect(run(&w, [true]) == [.userDown], "then the user card goes down")
expect(!w.userUp && run(&w, back).allSatisfy { $0 == .none }, "and nothing more after that")

// Busy QMP during the handover: unanswered polls do not count.
w = W()
_ = run(&w, down); _ = run(&w, back)
s = run(&w, [Bool?](repeating: nil, count: W.handover + 3))
expect(s.allSatisfy { $0 == .none } && w.userUp, "unanswered polls do not count toward the handover")
s = run(&w, [Bool?](repeating: true, count: W.handover + 1))
expect(s.last == .userDown, "answered ones do")

// vmnet goes again during the handover: back to the user network (its card
// is still up), no userDown in between.
w = W()
_ = run(&w, down); _ = run(&w, back)
s = run(&w, [true, true] + down)
expect(!s.contains(.userDown), "vmnet lost in the handover: the user card stays")
expect(s.contains(.toUser) && w.onUser && w.userUp, "and the VM goes back to the user network")
// Flapping vmnet (up, down, up ...) never takes the user card down.
w = W()
_ = run(&w, down); _ = run(&w, back)
s = run(&w, [true, true, true, false, true, true, true, false])
expect(!s.contains(.userDown) && w.userUp, "flapping vmnet: the user card stays")
s = run(&w, [Bool?](repeating: true, count: W.handover + 1))
expect(s.last == .userDown && s.dropLast().allSatisfy { $0 == .none }, "until vmnet holds for \(W.handover) polls in a row")

// A failed step is asked for again at every poll until it goes through.
w = W()
s = run(&w, down, ok: false)
expect(s.last == .toUser && !w.done, "failed switch: not done")
expect(w.poll(nil) == .toUser, "asked again at the next poll, also without an answer")
w.finished(.toUser, ok: true)
expect(w.done && w.userUp, "done once it went through")
_ = run(&w, back)
var left = 0
while w.poll(true) == .none { left += 1; if left > 20 { break } }
expect(left == W.handover, "handover of \(W.handover) polls")
w.finished(.userDown, ok: false)
expect(w.poll(true) == .userDown, "a failed userDown is asked for again")
w.finished(.userDown, ok: true)
expect(w.poll(true) == .none, "then nothing")

// A VM that never lost vmnet never takes a user card down.
w = W()
expect(run(&w, back + back).allSatisfy { $0 == .none }, "vmnet from the start: no steps")

// The Mac's proxy at a VM's start (MacProxy, #122): what scutil --proxy shows,
// as CFNetworkCopySystemProxySettings returns it.
let clash: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7890,
                            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7890,
                            "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 7891,
                            "ExceptionsList": ["*.local", "169.254/16"]]
var px = MacProxy(settings: clash)
expect(px.entries.map(\.kind) == ["http", "https", "socks"], "proxy: HTTP, HTTPS and SOCKS from the settings")
expect(px.loopbackPorts == [7890, 7891], "proxy: each port on 127.0.0.1 once")
expect(px.addingPorts(to: "47811,47830,47831") == "47811,47830,47831,7890,7891", "proxy: ports after OmacVM's")
expect(px.addingPorts(to: "") == "7890,7891", "proxy: no OmacVM ports (feature off): only the proxy's")
expect(px.addingPorts(to: "7890>7990") == "7890>7990,7891", "proxy: a port already listed is not added again")
expect(px.record(fastNetwork: false).hasPrefix("http 127.0.0.1:7890 (to the VM as 10.0.2.2:7890)"), "proxy: qemu.log line")
expect(px.record(fastNetwork: true).contains("not reachable on the fast network"), "proxy: the fast network cannot reach 127.0.0.1")
px = MacProxy(settings: ["SOCKSEnable": NSNumber(value: 1), "SOCKSProxy": "localhost", "SOCKSPort": NSNumber(value: 1080)])
expect(px.entries == [MacProxy.Entry(kind: "socks", host: "localhost", port: 1080)] && px.loopbackPorts == [1080], "proxy: SOCKS only, NSNumber values")
px = MacProxy(settings: ["HTTPEnable": 1, "HTTPProxy": "proxy.corp.example", "HTTPPort": 3128])
expect(px.loopbackPorts.isEmpty && px.addingPorts(to: "47811") == "47811", "proxy: another host needs no port")
px = MacProxy(settings: ["HTTPEnable": 0, "HTTPProxy": "127.0.0.1", "HTTPPort": 7890])
expect(px.entries.isEmpty && px.record(fastNetwork: false) == "none", "proxy: a proxy that is switched off is none")
px = MacProxy(settings: ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "http://wpad/proxy.pac"])
expect(px.entries.isEmpty && px.note?.contains("PAC") == true, "proxy: a PAC file is not read, and said so")
px = MacProxy(settings: ["ProxyAutoDiscoveryEnable": 1])
expect(px.entries.isEmpty && px.note?.contains("WPAD") == true, "proxy: WPAD is not done, and said so")
px = MacProxy(settings: ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 0])
expect(px.entries.isEmpty, "proxy: port 0 is no proxy")
// The environment wins over the settings (as for a build in a terminal).
px = MacProxy(settings: clash, environment: ["https_proxy": "http://user:pw@127.0.0.1:7897/", "ALL_PROXY": "socks5h://[::1]:7898"])
expect(px.source == "environment" && px.entries == [MacProxy.Entry(kind: "https", host: "127.0.0.1", port: 7897),
                                                    MacProxy.Entry(kind: "socks", host: "[::1]", port: 7898)], "proxy: from the environment, credentials and IPv6")
expect(px.loopbackPorts == [7897, 7898], "proxy: environment ports")
px = MacProxy(settings: [:], environment: ["http_proxy": "127.0.0.1"])
expect(px.loopbackPorts == [1080], "proxy: no port means 1080, as curl")
px = MacProxy(settings: [:], environment: ["http_proxy": "http://127.0.0.1:99999"])
expect(px.entries.isEmpty && px.note != nil, "proxy: a bad port is refused, and said so")
px = MacProxy(settings: [:], environment: ["http_proxy": ""])
expect(px.entries.isEmpty && px.source == "", "proxy: an empty variable is no proxy")

// The features file the Fast network button switches (FeaturesRecord).
let rec = "bridge=on autologin=off fast-network=off vulkan=off\n"
expect(FeaturesRecord.set(rec, "fast-network", on: true) == "bridge=on autologin=off fast-network=on vulkan=off\n",
       "record: fast-network on, the rest as it was")
expect(FeaturesRecord.set(rec, "fast-network", on: false) == rec, "record: off again is the same text")
expect(FeaturesRecord.set("bridge=on\n", "fast-network", on: true) == "bridge=on fast-network=on\n",
       "record: a fast-network the record does not name is added")
expect(FeaturesRecord.set("bridge=on fast-network-x=on\n", "fast-network", on: true) == "bridge=on fast-network-x=on fast-network=on\n",
       "record: only that name, not one that starts with it")

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")
