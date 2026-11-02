// drop-serve: OmacVM.app's side of drag and drop alone (DropServer, the code
// the app runs), for the hidden VM rows that start QEMU directly
// with a test hook in QEMU (OMACVM_DROP_TEST=1). Never part of the app.
//   drop-serve LISTEN PORT STAGE PIDFILE
//     LISTEN   QEMU's drop socket (OMACVM_DROP_SOCKET), in a 0700 folder
//     PORT     the org.omacvm.drop port's chardev socket
//     STAGE    the staging folder (QEMU's 9p share of it is read-only)
//     PIDFILE  QEMU's pid, written once QEMU runs (the peer check reads it)
// stdin, one per line: "drop PATH<TAB>PATH..." asks QEMU for a test drop
// (QEMU needs OMACVM_DROP_TEST=1); "delay MS" holds each drop that long
// before the VM hears of it; "ready?" prints ready or wait.
// Every log line goes to stdout.
import Foundation
import OmacVMDrop

setvbuf(stdout, nil, _IOLBF, 0)
let a = CommandLine.arguments
guard a.count == 5 else {
    FileHandle.standardError.write(Data("usage: drop-serve LISTEN PORT STAGE PIDFILE\n".utf8))
    exit(2)
}
let pidFile = a[4]
let server = DropServer(listenPath: a[1], portPath: a[2], stage: DropStage(root: a[3]),
                        qemuPID: { (try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } },
                        test: true) { print($0) }
do { try server.start() } catch {
    print("drop-serve: \(error)")
    exit(1)
}
print("drop-serve: listening")
while let line = readLine() {
    if line.hasPrefix("drop ") {
        let paths = line.dropFirst(5).split(separator: "\t").map(String.init)
        print(server.testDrop(paths: paths) ? "drop-serve: test drop asked" : "drop-serve: test drop not sent (QEMU not connected?)")
    } else if line.hasPrefix("delay "), let ms = Double(line.dropFirst(6)) {
        server.testDelay = ms / 1000
        print("drop-serve: delay \(Int(ms)) ms")
    } else if line == "ready?" {
        print(server.readyNow ? "drop-serve: ready" : "drop-serve: wait")
    }
}
server.stop()
