import AppKit
import Foundation
import OmacVMWindow
import SwiftUI

/// "omacvm in Terminal": a link to this app's own omacvm (rules and tests in
/// OmacVMWindow/CommandLineInstall.swift).
enum TerminalCommand {
    static var appCLI: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/omacvm/omacvm").path
    }

    /// The app has its own omacvm (not in a `swift run` from the source tree).
    static var available: Bool { FileManager.default.isExecutableFile(atPath: appCLI) }

    /// The PATH of a new Terminal window: the user's login shell asked once
    /// (five seconds at most), else macOS's default PATH (/etc/paths).
    static func userPath() -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-ilc", "printf '\\n@@PATH=%s@@\\n' \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        var text = ""
        if (try? p.run()) != nil {
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                done.signal()
            }
            if done.wait(timeout: .now() + 5) == .timedOut { p.terminate(); _ = done.wait(timeout: .now() + 1) }
        }
        if let r = text.range(of: "@@PATH="), let e = text.range(of: "@@", range: r.upperBound..<text.endIndex) {
            return String(text[r.upperBound..<e.lowerBound])
        }
        let etc = (try? String(contentsOfFile: "/etc/paths", encoding: .utf8)) ?? "/usr/local/bin\n/usr/bin\n/bin\n/usr/sbin\n/sbin"
        return etc.split(whereSeparator: \.isNewline).joined(separator: ":")
    }

    /// Off the main thread (asks the login shell).
    static func state() -> CommandLineInstall.State {
        CommandLineInstall.state(path: userPath(), home: VMsFolder.home.path, appCLI: appCLI)
    }

    /// Makes the link; nil when it worked, else why not. Looks again first:
    /// never over another omacvm.
    static func install() -> String? {
        let readOnly = (try? Bundle.main.bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        if let p = CommandLineInstall.placeProblem(appCLI: appCLI, readOnlyVolume: readOnly) { return p }
        guard case .available(let target, let admin) = state() else { return "Nothing to do: look again." }
        let cmd = CommandLineInstall.linkCommand(target: target, appCLI: appCLI)
        let p = Process()
        if admin {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "do shell script \(CommandLineInstall.appleScriptString(cmd)) with administrator privileges"]
        } else {
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", cmd]
        }
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return error.localizedDescription }
        let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            // osascript: -128 is Cancel in the password prompt.
            return msg.contains("-128") ? "Cancelled." : "Could not install: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        if case .installed = state() { return nil }
        return "Installed in \(target), but a new Terminal window does not find it first."
    }
}

/// The row in the VM window (and once in the first setup): a row of a form.
struct CommandLineRow: View {
    /// The window pictures: this state, shown also where the app has no omacvm.
    var preview: CommandLineInstall.State? = nil
    @State private var cli: CommandLineInstall.State?
    @State private var busy = false
    @State private var note: String?

    var body: some View {
        if TerminalCommand.available || preview != nil {
            LabeledContent("omacvm in Terminal") {
                HStack(spacing: 8) {
                    if let s = preview ?? cli {
                        Text(CommandLineInstall.shortText(s)).foregroundStyle(.secondary)
                        if case .available = s {
                            Button("Install") { install() }.disabled(busy)
                        }
                        if CommandLineInstall.text(s) != CommandLineInstall.shortText(s) {
                            InfoButton(topic: "omacvm in Terminal", text: CommandLineInstall.text(s))
                        }
                    }
                    if busy { ProgressView().controlSize(.small) }
                }
            }
            .onAppear { if preview == nil { refresh() } }
            if let n = note { RowNote(n, error: true) }
        }
    }

    private func refresh() {
        Task.detached {
            let s = TerminalCommand.state()
            await MainActor.run { cli = s }
        }
    }

    private func install() {
        busy = true
        note = nil
        Task.detached {
            let err = TerminalCommand.install()
            let s = TerminalCommand.state()
            await MainActor.run {
                busy = false
                note = err
                cli = s
            }
        }
    }
}
