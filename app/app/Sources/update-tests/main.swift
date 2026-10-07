// The self-update's checks (OmacVMUpdate), without Xcode:
//   cd app/app && swift run update-tests
// Exit 0 when all pass. CI runs it on every pull request.
import CryptoKit
import Foundation
import OmacVMUpdate
import Security

// A copy of this tool inside a fake app bundle plays a VM's QEMU (a copied
// system tool is killed: platform binaries only run from their place).
if CommandLine.arguments.dropFirst().first == "--sleep" { sleep(30); exit(0) }

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) (line \(line))"); failures += 1 }
}

// Versions
let v = { (s: String) in Version(s)! }
expect(v("2.10.0") > v("2.9.1"), "2.10.0 is newer than 2.9.1")
expect(v("2.7") == v("2.7.0"), "2.7 is 2.7.0")
expect(v("2.7.0") < v("2.7.1"), "2.7.0 is older than 2.7.1")
for bad in ["", "v2.7.0", "2.9.0 RC", "2.9.0-rc2", "1.2.3.4.5", "2..1", " ", "1234567.0"] {
    expect(Version(bad) == nil, "'\(bad)' is not a version")
}

// Update with a VM restart: the state file and the relay's answers
do {
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    let r = RestartVM(folder: "/Users/a/VMs/Omarchy", version: "3.0.2", at: at)
    expect(RestartVM.parse(r.line) == r, "restart-vm: the line reads back")
    expect(RestartVM.parse(r.line + "\n") == r, "restart-vm: with a newline")
    expect(r.fresh(now: at.addingTimeInterval(60)), "restart-vm: a minute old is fresh")
    expect(!r.fresh(now: at.addingTimeInterval(16 * 60)), "restart-vm: 16 minutes old is stale")
    expect(!r.fresh(now: at.addingTimeInterval(-3600)), "restart-vm: from the future is stale")
    for bad in ["", "relative\t3.0.2\t2027-01-15T08:00:00Z", "/a\tx\t2027-01-15T08:00:00Z", "/a\t3.0.2\tyesterday", "/a\t3.0.2"] {
        expect(RestartVM.parse(bad) == nil, "restart-vm: '\(bad)' is refused")
    }
    expect(RestartCheck.ready("3.0.2").answer.status == 202, "ready: 202 restarting")
    expect(RestartCheck.ready("3.0.2").answer.code == "restarting", "ready: code")
    expect(RestartCheck.upToDate("3.0.1").answer.code == "not-newer", "up to date: not-newer")
    expect(RestartCheck.busy("a VM is being built").answer.code == "busy", "busy")
    expect(RestartCheck.cannot("no key").answer.code == "app-cannot-update", "cannot update")
    expect(RestartCheck.needsMacOS("3.0.2", "26.0").answer.text.contains("macOS 26.0"), "needs macOS")
    expect(RestartCheck.failed("offline").answer.status == 502, "failed: 502")
    expect(RestartCheck.slow.answer.status == 504, "slow: 504, nothing shuts down")
    expect(RestartVM.answerWithin < 300, "the relay answers before the control centre gives up")
}

// When to check
let now = Date()
let day: TimeInterval = 24 * 3600
expect(UpdatePolicy.isDue(lastCheck: nil, now: now), "never checked: due")
expect(!UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(-6 * day), now: now), "6 days ago: not due")
expect(UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(-7 * day), now: now), "7 days ago: due")
expect(!UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(3600), now: now), "an hour ahead (clock skew): not due")
expect(UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(2 * day), now: now), "2 days ahead (clock went back): due")

// The feed: signature first (either release key), then strict fields.
// Throwaway keys: "main" and "spare" play the two shipped ones.
let key = Curve25519.Signing.PrivateKey()
let spareKey = Curve25519.Signing.PrivateKey()
func b64(_ k: Curve25519.Signing.PrivateKey) -> String { k.publicKey.rawRepresentation.base64EncodedString() }
let pub = b64(key)
let shipped = ReleaseKeys(shipped: [pub, b64(spareKey)], store: nil)
let sha = String(repeating: "ab", count: 32)
func feed(_ fields: [String: Any]) -> Data {
    var o: [String: Any] = ["schema": 1, "kind": "app-feed", "version": "2.9.1", "url": "https://github.com/gillesgoetsch/omacvm/releases/download/v2.9.1/OmacVM-2.9.1.zip",
                            "length": 61_234_567, "sha256": sha, "minimum_macos": "15.0",
                            "notes_url": "https://github.com/gillesgoetsch/omacvm/releases/tag/v2.9.1",
                            "devid_teams": ["722686Y34B"]]
    for (k, val) in fields { o[k] = val is NSNull ? nil : val }
    return try! JSONSerialization.data(withJSONObject: o, options: .sortedKeys)
}
func sign(_ d: Data, with k: Curve25519.Signing.PrivateKey = key) -> Data {
    Data((try! k.signature(for: d)).base64EncodedString().utf8 + [0x0a])
}
let good = feed([:])
if case .success(let a) = Appcast.verified(feed: good, signature: sign(good), keys: shipped) {
    expect(a.version == v("2.9.1") && a.length == 61_234_567 && a.sha256 == sha && a.minimumMacOS == v("15.0")
           && a.teams == ["722686Y34B"] && a.nextSpareKey == nil, "a good feed reads (signed with the main key)")
} else { expect(false, "a good feed reads (signed with the main key)") }
if case .success = Appcast.verified(feed: good, signature: sign(good, with: spareKey), keys: shipped) {
    expect(true, "signed with the spare key: accepted")
} else { expect(false, "signed with the spare key: accepted") }
var tampered = good; tampered[tampered.count / 2] ^= 1
expect(Appcast.verified(feed: tampered, signature: sign(good), keys: shipped) == .failure(.badSignature), "one changed byte: refused")
expect(Appcast.verified(feed: good, signature: sign(good, with: Curve25519.Signing.PrivateKey()), keys: shipped) == .failure(.badSignature),
       "signed with another key: refused")
expect(Appcast.verified(feed: good, signature: sign(good, with: spareKey), keys: ReleaseKeys(shipped: [pub], store: nil)) == .failure(.badSignature),
       "the spare's signature where only the main key ships: refused")
expect(Appcast.verified(feed: good, signature: Data("garbage".utf8), keys: shipped) == .failure(.badSignature), "garbage signature: refused")
expect(Appcast.verified(feed: good, signature: sign(good), keys: ReleaseKeys(shipped: [], store: nil)) == .failure(.noKey), "no key: refused")
expect(Appcast.verified(feed: good, signature: sign(good), keys: ReleaseKeys(shipped: ["", "bm90IGEga2V5"], store: nil)) == .failure(.noKey),
       "only broken keys: refused")
let big = Data(repeating: 0x20, count: Appcast.maxFeedBytes + 1)
expect(Appcast.verified(feed: big, signature: sign(big), keys: shipped) == .failure(.tooLarge), "oversized feed: refused")
let bad: [(String, [String: Any])] = [
    ("schema 2", ["schema": 2]), ("no kind", ["kind": NSNull()]), ("the control centre's manifest", ["kind": "control-manifest"]),
    ("kind as a number", ["kind": 1]), ("version with a suffix", ["version": "2.9.1-rc1"]),
    ("length as a bool", ["length": true]), ("negative length", ["length": -1]), ("fractional length", ["length": 1.5]),
    ("length over 2 GB", ["length": Int64(3) << 30]), ("upper-case digest", ["sha256": sha.uppercased()]),
    ("short digest", ["sha256": "abc"]), ("http to another host", ["url": "http://example.com/OmacVM.zip"]),
    ("file URL", ["url": "file:///tmp/OmacVM.zip"]), ("notes over http", ["notes_url": "http://example.com"]),
    ("no url", ["url": NSNull()]), ("minimum_macos as a number", ["minimum_macos": 15]),
    ("no devid_teams", ["devid_teams": NSNull()]), ("empty devid_teams", ["devid_teams": [String]()]),
    ("devid_teams as a string", ["devid_teams": "722686Y34B"]), ("lower-case team", ["devid_teams": ["722686y34b"]]),
    ("short team", ["devid_teams": ["722686Y34"]]), ("team with a quote", ["devid_teams": ["722686Y3\"B"]]),
    ("team twice", ["devid_teams": ["722686Y34B", "722686Y34B"]]), ("five teams", ["devid_teams": ["AAAAAAAAA1", "AAAAAAAAA2", "AAAAAAAAA3", "AAAAAAAAA4", "AAAAAAAAA5"]]),
    ("team as a number", ["devid_teams": [1234567890]]), ("next_spare_key not a key", ["next_spare_key": "bm90IGEga2V5"]),
    ("next_spare_key as a number", ["next_spare_key": 1]),
    ("revoked_keys empty", ["revoked_keys": [String]()]), ("revoked_keys as a string", ["revoked_keys": pub]),
    ("revoked_keys not a key", ["revoked_keys": ["bm90IGEga2V5"]]), ("revoked_keys twice the same", ["revoked_keys": [pub, pub]]),
]
for (what, change) in bad {
    let f = feed(change)
    if case .failure(.malformed) = Appcast.verified(feed: f, signature: sign(f), keys: shipped) {
        expect(true, "\(what): refused")
    } else { expect(false, "\(what): refused") }
}
let local = feed(["url": "http://127.0.0.1:8765/OmacVM.zip"])
if case .success = Appcast.verified(feed: local, signature: sign(local), keys: shipped) { expect(true, "http to 127.0.0.1 (a test feed): allowed") }
else { expect(false, "http to 127.0.0.1 (a test feed): allowed") }

let twoTeams = feed(["devid_teams": ["722686Y34B", "ABCDE12345"]])
if case .success(let a) = Appcast.verified(feed: twoTeams, signature: sign(twoTeams), keys: shipped) {
    expect(a.teams == ["722686Y34B", "ABCDE12345"], "two teams (a change of Developer ID): both read")
} else { expect(false, "two teams (a change of Developer ID): both read") }

// What to offer
if case .success(let a) = Appcast.verified(feed: good, signature: sign(good), keys: shipped) {
    let os = v("15.7.4")
    expect(UpdatePolicy.offer(a, current: v("2.9.1"), skipped: nil, os: os) == .upToDate, "same version: nothing")
    expect(UpdatePolicy.offer(a, current: v("3.0.0"), skipped: nil, os: os) == .upToDate, "older feed (replayed): nothing")
    expect(UpdatePolicy.offer(a, current: v("2.7.0"), skipped: nil, os: os) == .newer, "newer: offered")
    expect(UpdatePolicy.offer(a, current: v("2.7.0"), skipped: "2.9.1", os: os) == .skipped, "skipped version: not offered")
    expect(UpdatePolicy.offer(a, current: v("2.7.0"), skipped: "2.8.0", os: os) == .newer, "newer than the skipped one: offered")
    expect(UpdatePolicy.offer(a, current: v("2.7.0"), skipped: nil, os: v("14.6")) == .needsMacOS("15.0"), "too old a macOS: not offered")
}

// Test hooks: only in test builds
let hookEnv = ["OMACVM_APPCAST_URL": "http://127.0.0.1:1/feed.json", "OMACVM_APPCAST_KEY": ""]
expect(!TestHooks.allowed(bundleID: "org.omacvm.app"), "release build: no test hooks")
expect(!TestHooks.allowed(bundleID: nil) && !TestHooks.allowed(bundleID: ""), "no bundle id: no test hooks")
expect(TestHooks.allowed(bundleID: "org.omacvm.sutest"), "test build: test hooks")
expect(TestHooks.value("OMACVM_APPCAST_URL", bundleID: "org.omacvm.app", environment: hookEnv) == nil, "release build: feed URL hook ignored")
expect(TestHooks.value("OMACVM_APPCAST_URL", bundleID: "org.omacvm.sutest", environment: hookEnv) == "http://127.0.0.1:1/feed.json",
       "test build: feed URL hook read")
expect(TestHooks.value("OMACVM_APPCAST_KEY", bundleID: "org.omacvm.sutest", environment: hookEnv) == nil, "empty hook: unset")

// The shared switch (control centre and app)
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("omacvm-update-tests-\(getpid())")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let settings = SharedSettings(directory: tmp.appendingPathComponent("support"))
expect(settings.updateChecks, "no settings file: checks on")
try! FileManager.default.createDirectory(at: settings.file.deletingLastPathComponent(), withIntermediateDirectories: true)
try! Data(#"{"update_checks": 0, "other": "kept"}"#.utf8).write(to: settings.file)
expect(settings.updateChecks, "update_checks 0 (not a bool): on")
try! settings.setUpdateChecks(false)
expect(!settings.updateChecks, "switched off: off")
let kept = (try? JSONSerialization.jsonObject(with: Data(contentsOf: settings.file))) as? [String: Any]
expect(kept?["other"] as? String == "kept", "other keys kept")
try! Data("not json".utf8).write(to: settings.file)
expect(settings.updateChecks, "unreadable file: on")

// Files
let abc = tmp.appendingPathComponent("abc")
try! Data("abc".utf8).write(to: abc)
expect((try? Files.sha256(abc)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 of a file")
let unpacked = tmp.appendingPathComponent("unpacked")
try! FileManager.default.createDirectory(at: unpacked.appendingPathComponent("OmacVM.app/Contents"), withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: unpacked.appendingPathComponent("__MACOSX"), withIntermediateDirectories: true)
expect(Files.singleApp(in: unpacked)?.lastPathComponent == "OmacVM.app", "one app in the zip: found")
try! FileManager.default.createSymbolicLink(at: unpacked.appendingPathComponent("Other.app"), withDestinationURL: tmp)
expect(Files.singleApp(in: unpacked) == nil, "two apps in the zip: refused")
let linked = tmp.appendingPathComponent("linked")
try! FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
try! FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("OmacVM.app"), withDestinationURL: unpacked)
expect(Files.singleApp(in: linked) == nil, "an app that is a link: refused")

// Code signatures: Apple's own tools are valid but not of a team the feed names
let req = CodeCheck.developerID(teams: ["722686Y34B", "ABCDE12345"])
var parsed: SecRequirement?
expect(SecRequirementCreateWithString(req as CFString, [], &parsed) == errSecSuccess, "requirement for two teams compiles")
expect(req.contains(#"(certificate leaf[subject.OU] = "722686Y34B" or certificate leaf[subject.OU] = "ABCDE12345")"#),
       "requirement: either team")
expect(CodeCheck.problem(URL(fileURLWithPath: "/bin/ls"), requirement: nil) == nil, "/bin/ls has a valid signature")
expect(CodeCheck.problem(URL(fileURLWithPath: "/bin/ls"), requirement: req)?.contains("Developer ID") == true,
       "/bin/ls is not signed by a team the feed names")
// Apple's own tools are signed by Apple, not a Developer ID: no team list lets them pass.
expect(CodeCheck.problem(URL(fileURLWithPath: "/bin/ls"), requirement: CodeCheck.developerID(teams: ["0000000000"])) != nil,
       "another team: refused")
let unsigned = tmp.appendingPathComponent("unsigned")
try! Data("#!/bin/sh\n".utf8).write(to: unsigned)
expect(CodeCheck.problem(unsigned, requirement: req) != nil, "an unsigned file: refused")

// A Developer ID signed app (OMACVM_TEST_DEVID_APP, e.g. a test build made
// with OMACVM_SIGN_ID): its own team passes, another team does not.
if let path = ProcessInfo.processInfo.environment["OMACVM_TEST_DEVID_APP"], !path.isEmpty {
    let app = URL(fileURLWithPath: path)
    var code: SecStaticCode?
    var info: CFDictionary?
    SecStaticCodeCreateWithPath(app as CFURL, [], &code)
    if let code { SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) }
    let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String ?? ""
    expect(CodeCheck.teams([team]) != nil, "test app has a team (\(team))")
    expect(CodeCheck.problem(app, requirement: CodeCheck.developerID(teams: [team])) == nil, "its own team: accepted")
    expect(CodeCheck.problem(app, requirement: CodeCheck.developerID(teams: ["0000000000", team])) == nil, "its team second in the list: accepted")
    expect(CodeCheck.problem(app, requirement: CodeCheck.developerID(teams: ["0000000000"]))?.contains("Developer ID") == true,
           "another team only: refused")
} else {
    print("skip a Developer ID signed app (set OMACVM_TEST_DEVID_APP)")
}

// Release keys: a feed may name a new spare, kept as the signed feed itself
let store = tmp.appendingPathComponent("support/release-keys")
let rotating = ReleaseKeys(shipped: [pub, b64(spareKey)], store: store)
let nextKey = Curve25519.Signing.PrivateKey()
let announce = feed(["next_spare_key": b64(nextKey), "version": "2.9.2"])
if case .success(let a) = Appcast.verified(feed: announce, signature: sign(announce, with: spareKey), keys: rotating) {
    expect(a.nextSpareKey == b64(nextKey), "a feed naming a new spare reads")
} else { expect(false, "a feed naming a new spare reads") }
let byNext = feed(["version": "2.9.3"])
expect(Appcast.verified(feed: byNext, signature: sign(byNext, with: nextKey), keys: rotating) == .failure(.badSignature),
       "the new spare before it was named: refused")
expect(rotating.remember(announce, signature: sign(announce, with: Curve25519.Signing.PrivateKey())) == nil,
       "a naming feed signed by a stranger: not kept")
expect(rotating.remember(feed([:]), signature: sign(feed([:]))) == nil, "a feed naming nothing: nothing kept")
expect(rotating.remember(announce, signature: sign(announce, with: spareKey))?.named == [b64(nextKey)], "the named spare is kept")
expect(rotating.remember(announce, signature: sign(announce, with: spareKey)) == nil, "named again: already trusted")
if case .success = Appcast.verified(feed: byNext, signature: sign(byNext, with: nextKey), keys: rotating) {
    expect(true, "signed with the named spare: accepted from then on")
} else { expect(false, "signed with the named spare: accepted from then on") }
let keptFiles = (try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? []
expect(keptFiles.count == 2 && keptFiles.contains { $0.hasSuffix(".json.sig") }, "kept as the feed and its signature (\(keptFiles))")
// The named spare names the next one: a chain.
let thirdKey = Curve25519.Signing.PrivateKey()
let announce2 = feed(["next_spare_key": b64(thirdKey), "version": "2.9.4"])
expect(rotating.remember(announce2, signature: sign(announce2, with: nextKey))?.named == [b64(thirdKey)], "the named spare names another")
expect(rotating.trusted().count == 4, "trusted: main, spare and the two named")
// A copy that ships other keys does not trust what the old ones named.
expect(ReleaseKeys(shipped: [b64(Curve25519.Signing.PrivateKey())], store: store).trusted().count == 1,
       "shipped keys changed: the kept documents no longer count")
// A kept document changed on disk (a key put in by another process): ignored.
for name in keptFiles where name.hasSuffix(".json") {
    var d = try! Data(contentsOf: store.appendingPathComponent(name))
    d[d.count / 2] ^= 1
    try! d.write(to: store.appendingPathComponent(name))
}
expect(rotating.trusted().count == 2, "a changed kept document: its key (and the chain after it) not trusted")
expect(Appcast.verified(feed: byNext, signature: sign(byNext, with: nextKey), keys: rotating) == .failure(.badSignature),
       "after the change: the named spare refused again")
// A bare key file dropped in the folder means nothing.
try! Data(b64(nextKey).utf8).write(to: store.appendingPathComponent("0123456789abcdef.json"))
try! Data("x".utf8).write(to: store.appendingPathComponent("0123456789abcdef.json.sig"))
expect(rotating.trusted().count == 2, "a bare key file in the folder: not trusted")

// A named spare that leaked: a feed signed by a shipped key revokes it (docs/release-keys.md).
func fresh(_ name: String) -> ReleaseKeys {
    let d = tmp.appendingPathComponent("support-\(name)/release-keys")
    try? FileManager.default.removeItem(at: d)
    return ReleaseKeys(shipped: [pub, b64(spareKey)], store: d)
}
func trusts(_ k: ReleaseKeys, _ key: Curve25519.Signing.PrivateKey) -> Bool {
    k.trusted().contains { $0.rawRepresentation == key.publicKey.rawRepresentation }
}
let revoking = fresh("revoke")
_ = revoking.remember(announce, signature: sign(announce, with: spareKey))
_ = revoking.remember(announce2, signature: sign(announce2, with: nextKey))
expect(revoking.trusted().count == 4, "before: main, spare and two named")
let leakedRevokes = feed(["revoked_keys": [pub, b64(spareKey)], "version": "2.9.5"])
expect(revoking.remember(leakedRevokes, signature: sign(leakedRevokes, with: nextKey)) == nil && trusts(revoking, key) && trusts(revoking, spareKey),
       "a named spare revoking the shipped keys: ignored")
let selfRevoke = feed(["revoked_keys": [b64(spareKey)], "version": "2.9.5"])
expect(revoking.remember(selfRevoke, signature: sign(selfRevoke)) == nil && trusts(revoking, spareKey),
       "a shipped key revoked by a document: ignored (a release drops it)")
let revoke = feed(["revoked_keys": [b64(nextKey)], "version": "2.9.6"])
if case .success = Appcast.verified(feed: revoke, signature: sign(revoke), keys: revoking) { expect(true, "a feed with revoked_keys reads") }
else { expect(false, "a feed with revoked_keys reads") }
let kept1 = revoking.remember(revoke, signature: sign(revoke))
expect(kept1?.named == [] && kept1?.revoked == [b64(nextKey)], "the revocation is kept")
expect(!trusts(revoking, nextKey) && !trusts(revoking, thirdKey) && revoking.trusted().count == 2,
       "the revoked key and the one it named: not trusted any more")
expect(Appcast.verified(feed: byNext, signature: sign(byNext, with: nextKey), keys: revoking) == .failure(.badSignature),
       "a feed signed by the revoked key: refused")
expect(revoking.remember(revoke, signature: sign(revoke)) == nil, "revoked again: nothing kept")
// A later release ships the spare as main (the old main lost): the main key's revocation no longer counts...
let rotated = ReleaseKeys(shipped: [b64(spareKey), b64(Curve25519.Signing.PrivateKey())], store: revoking.store)
expect(trusts(rotated, nextKey), "shipped keys rotated: a revocation only the old main signed no longer counts")
// ...so the release signed by the spare lists the leaked key again; copies keep that one too.
let revokeBySpare = feed(["revoked_keys": [b64(nextKey)], "version": "2.9.9"])
expect(revoking.remember(revokeBySpare, signature: sign(revokeBySpare, with: spareKey)) != nil, "the same revocation signed by the spare: kept as well")
expect(!trusts(rotated, nextKey) && !trusts(rotated, thirdKey), "after the rotation the leaked key stays revoked")
let again = feed(["revoked_keys": [b64(nextKey)], "version": "3.0.0"])
expect(revoking.remember(again, signature: sign(again, with: spareKey)) == nil, "a third copy of it: nothing kept")
let renamed = feed(["next_spare_key": b64(nextKey), "version": "2.9.7"])
expect(revoking.remember(renamed, signature: sign(renamed)) == nil && !trusts(revoking, nextKey), "a revoked key named again: not trusted")
let other = Curve25519.Signing.PrivateKey()
let both = feed(["next_spare_key": b64(other), "revoked_keys": [b64(nextKey)], "version": "2.9.8"])
let fresh2 = fresh("both")
_ = fresh2.remember(announce, signature: sign(announce, with: spareKey))
let kept2 = fresh2.remember(both, signature: sign(both))
expect(kept2?.named == [b64(other)] && kept2?.revoked == [b64(nextKey)] && fresh2.trusted().count == 3,
       "one feed revokes the leaked spare and names a new one")
// The leaked spare filled the folder with documents of its own: the revocation still gets in.
let filled = fresh("filled")
_ = filled.remember(announce, signature: sign(announce, with: spareKey))
var signer = nextKey
for i in 0..<10 {
    let k = Curve25519.Signing.PrivateKey()
    let d = feed(["next_spare_key": b64(k), "version": "3.0.\(i)"])
    _ = filled.remember(d, signature: sign(d, with: signer))
    signer = k
}
expect(filled.trusted().count == 2 + ReleaseKeys.maxKept, "at most \(ReleaseKeys.maxKept) kept documents count")
expect(filled.remember(revoke, signature: sign(revoke)) != nil && filled.trusted().count == 2, "a full folder: the revocation is kept, the chain dropped")
// Junk in the folder (names that sort first) counts toward nothing.
let junky = fresh("junk")
try! FileManager.default.createDirectory(at: junky.store!, withIntermediateDirectories: true)
for i in 0..<20 {
    let n = String(format: "%016x", i)
    try! feed(["next_spare_key": b64(Curve25519.Signing.PrivateKey())]).write(to: junky.store!.appendingPathComponent("\(n).json"))
    try! sign(feed([:]), with: Curve25519.Signing.PrivateKey()).write(to: junky.store!.appendingPathComponent("\(n).json.sig"))
}
expect(junky.trusted().count == 2, "20 junk documents: nothing trusted from them")
expect(junky.remember(announce, signature: sign(announce, with: spareKey))?.named == [b64(nextKey)] && junky.trusted().count == 3,
       "20 junk documents first: a real one is still kept and trusted")
// More junk than the old 256-file cap, on both sides of the real names, plus a
// link and a pipe named like documents: all of it is read past, nothing hangs.
let flood = fresh("flood")
try! FileManager.default.createDirectory(at: flood.store!, withIntermediateDirectories: true)
let junkDoc = feed(["next_spare_key": b64(Curve25519.Signing.PrivateKey())]), junkSig = sign(feed([:]), with: Curve25519.Signing.PrivateKey())
for i in 0..<300 {
    for n in [String(format: "%016x", i), String(format: "ffffffff%08x", i)] {
        try! junkDoc.write(to: flood.store!.appendingPathComponent("\(n).json"))
        try! junkSig.write(to: flood.store!.appendingPathComponent("\(n).json.sig"))
    }
}
expect(flood.remember(announce, signature: sign(announce, with: spareKey)) != nil
       && flood.remember(announce2, signature: sign(announce2, with: nextKey)) != nil && flood.trusted().count == 4,
       "600 junk documents around them: a chain of two named keys is still kept and trusted")
expect(mkfifo(flood.store!.appendingPathComponent("00000000000b0000.json").path, 0o600) == 0
       && mkfifo(flood.store!.appendingPathComponent("00000000000b0000.json.sig").path, 0o600) == 0, "a pipe named like a document")
expect(flood.trusted().count == 4, "a pipe in the folder: skipped, no hang")
// A kept document swapped for a link to itself elsewhere: links are not followed.
let real = try! FileManager.default.contentsOfDirectory(atPath: flood.store!.path).first { !$0.hasPrefix("0000") && !$0.hasPrefix("ffffffff") && $0.hasSuffix(".json") }!
let away = tmp.appendingPathComponent("away.json")
try? FileManager.default.removeItem(at: away)
try! FileManager.default.moveItem(at: flood.store!.appendingPathComponent(real), to: away)
try! FileManager.default.createSymbolicLink(at: flood.store!.appendingPathComponent(real), withDestinationURL: away)
expect(flood.trusted().count < 4, "a kept document that is a link: not followed")
// The same document under another name (a copy): skipped before its signature is checked.
let copyName = "0123456789abcdef.json"
try! FileManager.default.copyItem(at: away, to: flood.store!.appendingPathComponent(copyName))
try! FileManager.default.copyItem(at: flood.store!.appendingPathComponent(real + ".sig"), to: flood.store!.appendingPathComponent(copyName + ".sig"))
expect(flood.trusted().count < 4, "a kept document under a name that is not its hash: skipped")
let crowded = fresh("crowded")
for i in 0..<(3 * ReleaseKeys.maxKept) {
    let d = feed(["next_spare_key": b64(Curve25519.Signing.PrivateKey()), "version": "4.0.\(i)"])
    let sig = sign(d), n = SHA256.hash(data: d + sig).prefix(8).map { String(format: "%02x", $0) }.joined()
    try! FileManager.default.createDirectory(at: crowded.store!, withIntermediateDirectories: true)
    try! d.write(to: crowded.store!.appendingPathComponent("\(n).json"))
    try! sig.write(to: crowded.store!.appendingPathComponent("\(n).json.sig"))
}
expect(crowded.trusted().count == 2 + ReleaseKeys.maxKept, "\(3 * ReleaseKeys.maxKept) signed documents in the folder: still at most \(ReleaseKeys.maxKept) count")

// Who may replace the bundle: its folder and the bundle itself writable
let folder = tmp.appendingPathComponent("Applications")
let mine = folder.appendingPathComponent("OmacVM.app")
try! FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
expect(UpdatePolicy.writeProblem(bundle: mine) == nil, "own folder and bundle: can update")
try! FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: mine.path)
expect(UpdatePolicy.writeProblem(bundle: mine)?.contains("OmacVM.app is not writable") == true, "bundle not writable: says so")
try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mine.path)
try! FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
expect(UpdatePolicy.writeProblem(bundle: mine)?.contains("Applications is not writable") == true, "folder not writable: says so")
try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)

// Processes from inside a bundle (a VM's QEMU)
let fake = tmp.appendingPathComponent("Fake.app")
let exe = fake.appendingPathComponent("Contents/MacOS/qemu")
try! FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
try! FileManager.default.copyItem(at: Bundle.main.executableURL!, to: exe)
let p = Process()
p.executableURL = exe
p.arguments = ["--sleep"]
try! p.run()
usleep(200_000)
expect(Running.pids(inside: fake).contains(p.processIdentifier), "a process from inside the bundle is seen")
expect(Running.pids(inside: tmp.appendingPathComponent("Other.app")).isEmpty, "another bundle: nothing")
p.terminate(); p.waitUntilExit()
expect(Running.pids(inside: fake).isEmpty, "after it ends: nothing")

// One update folder per copy; the swap's work folder on the app's volume
let copyA = folder.appendingPathComponent("OmacVM.app")
let copyB = tmp.appendingPathComponent("Other place/OmacVM.app")
try! FileManager.default.createDirectory(at: copyB, withIntermediateDirectories: true)
let keyA = UpdateFolders.key(for: copyA)
expect(keyA.range(of: "^OmacVM-[0-9a-f]{8}$", options: .regularExpression) != nil, "folder key: name and 8 hex digits (\(keyA))")
expect(keyA != UpdateFolders.key(for: copyB), "two copies with one name: two folders")
expect(keyA == UpdateFolders.key(for: copyA), "the same copy: the same folder")
let viaLink = tmp.appendingPathComponent("link")
try! FileManager.default.createSymbolicLink(at: viaLink, withDestinationURL: folder)
expect(UpdateFolders.key(for: viaLink.appendingPathComponent("OmacVM.app")) == keyA, "reached through a link: the same folder")
expect(UpdateFolders.key(for: folder.appendingPathComponent("Omarchy.app")).hasPrefix("Omarchy-"), "a renamed copy: its own name")
let home = tmp.appendingPathComponent("support/Updates/org.omacvm.app/\(keyA)")
expect(UpdateFolders.device(home) == UpdateFolders.device(tmp), "a folder not made yet: its parent's volume")
expect(UpdateFolders.work(for: copyA, home: home) == home, "app on the update folder's volume: work there")
// /dev (devfs) is another volume than the temporary folder.
let elsewhere = URL(fileURLWithPath: "/dev/OmacVM.app")
expect(UpdateFolders.device(URL(fileURLWithPath: "/dev")) != UpdateFolders.device(tmp), "/dev is another volume")
expect(UpdateFolders.work(for: elsewhere, home: home).path == "/dev/.omacvm-updates/\(UpdateFolders.key(for: elsewhere))",
       "app on another volume: work next to it")

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
