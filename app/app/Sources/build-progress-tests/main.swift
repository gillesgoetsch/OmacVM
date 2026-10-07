// The build window's progress (OmacVMBuildProgress), without a VM or Xcode:
//   cd app/app && swift run build-progress-tests
// Exit 0 when all pass. CI runs it on every pull request.
import Foundation
import OmacVMBuildProgress

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) (line \(line))"); failures += 1 }
}
typealias P = ProgressUpdate

// Lines as src/vm/progress.sh and vm-common.sh print them.
let dl = P.parse(#"{"omacvm_progress": 1, "phase": "download", "now": "hyprland", "n": 14, "of": 190, "done": 1000, "total": 289144832}"#)
expect(dl == P(phase: .download, now: "hyprland", n: 14, of: 190, done: 1000, total: 289144832), "package download line")
expect(dl?.text == "Downloading hyprland (14 of 190 packages)", "its text")
let inst = P.parse(#"{"omacvm_progress": 1, "phase": "install", "now": "linux-aarch64", "n": 312, "of": 1104}"#)
expect(inst?.text == "Installing linux-aarch64 (312 of 1104 packages)", "install text")
expect(inst?.fraction.map { abs($0 - 312.0 / 1104) < 1e-9 } == true, "install fraction from the count")
let live = P.parse(#"{"omacvm_progress": 1, "phase": "download", "now": "try-omarchy", "done": 500, "total": 1000}"#)
expect(live?.text == "Downloading try-omarchy" && live?.fraction == 0.5, "Mac download: bytes")
expect(P.parse(#"{"omacvm_progress": 1, "phase": "download", "now": "", "n": 0, "of": 213}"#)?.text == "Downloading packages (0 of 213)",
       "a download before its first package")
expect(P.parse(#"{"omacvm_progress": 1, "phase": "download", "now": "prebuilt VM", "done": 2000, "total": 1000}"#)?.done == 1000, "done capped at total")

// The VM is untrusted: anything odd is dropped.
expect(P.parse(#"{"omacvm_progress": 1, "phase": "install", "now": "x\u001b]0;evil\u0007", "n": 1, "of": 2}"#) == nil, "control characters in the name")
expect(P.parse(#"{"omacvm_progress": 1, "phase": "install", "now": "\#(String(repeating: "a", count: 61))", "n": 1, "of": 2}"#) == nil, "name too long")
expect(P.parse(#"{"omacvm_progress": 1, "phase": "install", "now": "x", "n": 5, "of": 2}"#) == nil, "n beyond of")
expect(P.parse(#"{"omacvm_progress": 1, "phase": "install", "now": "x", "n": -1, "of": 2}"#) == nil, "negative count")
expect(P.parse(#"{"omacvm_progress": 1, "phase": "install", "now": "x", "n": 1, "of": 1000000}"#) == nil, "huge count")
expect(P.parse(#"{"omacvm_progress": 1, "phase": "download", "done": 1e30, "total": 5}"#) == nil, "huge bytes")
expect(P.parse(#"{"omacvm_progress": 1, "phase": "download", "done": 1.5, "total": 5}"#) == nil, "fractional bytes")
expect(P.parse(#"{"omacvm_progress": 1, "phase": "download", "done": "5", "total": 5}"#) == nil, "bytes as text")
expect(P.parse(#"{"omacvm_progress": 1, "phase": "explode"}"#) == nil, "unknown phase")
expect(P.parse(#"{"omacvm_progress": 2, "phase": "install"}"#) == nil, "unknown version")
expect(P.parse(#"{"omacvm_progress": 1, broken"#) == nil, "broken JSON")
expect(P.parse("{\"omacvm_progress\": 1, \"phase\": \"install\", \"now\": \"\(String(repeating: " ", count: 600))\"}") == nil, "line too long")
expect(P.parse("==> pacstrap") == nil, "not a progress line")

// Speed: smoothed over the window, and ETA.
var r = ByteRate(window: 8)
expect(r.bytesPerSecond == nil, "no speed before readings")
for s in 0...10 { r.add(Int64(s) * 10_000_000, at: Double(s)) }
expect(r.bytesPerSecond.map { abs($0 - 10_000_000) < 1 } == true, "10 MB/s steady")
expect(r.secondsLeft(total: 200_000_000).map { abs($0 - 10) < 0.01 } == true, "10 s left for 100 MB more")
r.add(100_000_000, at: 11)   // a stalled second
expect(r.bytesPerSecond.map { $0 > 8_000_000 } == true, "one stalled second barely moves it")
r.add(5, at: 12)             // a new file: starts over
expect(r.bytesPerSecond == nil, "a smaller reading starts over")
expect(BuildText.speed(11_200_000) == "11.2 MB/s" && BuildText.speed(500_000) == "500 KB/s", "speed text")
expect(BuildText.bytes(1_437_631_926) == "1.4 GB" && BuildText.bytes(412_000_000) == "412 MB", "bytes text")
expect(BuildText.duration(12) == "12 s" && BuildText.duration(80) == "1 min 20 s" && BuildText.duration(840) == "14 min"
       && BuildText.duration(3900) == "1 h 5 min", "durations")
expect(BuildText.left(30) == "less than a minute left" && BuildText.left(170) == "about 3 min left"
       && BuildText.left(1400) == "about 25 min left", "time left, rounded")
expect(BuildText.heartbeat(quietFor: 1) == "Working." && BuildText.heartbeat(quietFor: 4) == "Working. Last output 4 s ago.",
       "heartbeat")
expect(BuildText.heartbeat(quietFor: 300).hasPrefix("Still working. No output for 5 min"), "a long quiet part")

// Details: the log's tail, readable.
let log = "| installing gum...\n{\"omacvm_progress\": 1, \"phase\": \"install\"}\n\u{1B}[1;32m==>\u{1B}[0m pacstrap\n| \u{1B}]0;title\u{07}x\n\n"
expect(BuildText.tail(Data(log.utf8)) == ["installing gum...", "==> pacstrap", "]0;titlex"], "log tail: marks, progress, colours and controls out")
let many = (1...50).map { "| line \($0)" }.joined(separator: "\n")
expect(BuildText.tail(Data(many.utf8)) == (31...50).map { "line \($0)" }, "the last 20 lines")

// Usual step times.
let slow = StepTimes.usual(route: .build, step: 4, performanceCores: 4)!
let quick = StepTimes.usual(route: .build, step: 4, performanceCores: 10)!
expect(quick.1 < slow.1, "a Pro/Max chip is quicker")
expect(StepTimes.usualText(slow) == "usually 5-20 min", "usual text: \(StepTimes.usualText(slow))")
expect(StepTimes.usualText((15, 60)) == "usually 15 s to 1 min" && StepTimes.usualText((10, 50)) == "usually 10-50 s", "usual text across units")
expect(StepTimes.usual(route: .prebuilt, step: 2, performanceCores: 4) == nil, "a download has no usual time")

let d = UserDefaults(suiteName: "org.omacvm.test.build-progress.\(getpid())")!
StepTimes.remember([2: 95, 4: 1300], route: .build, defaults: d)
expect(StepTimes.last(route: .build, step: 4, defaults: d) == 1300 && StepTimes.last(route: .build, step: 3, defaults: d) == nil
       && StepTimes.last(route: .prebuilt, step: 4, defaults: d) == nil, "last build's step times")
d.removePersistentDomain(forName: "org.omacvm.test.build-progress.\(getpid())")

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
