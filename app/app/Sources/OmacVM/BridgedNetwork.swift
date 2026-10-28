import Foundation
import OmacVMNet

/// Bridged LAN traffic and private host management never share a default route.
enum BridgedNetwork {
    static func isOn(_ c: VMConfig) -> Bool {
        FileManager.default.fileExists(atPath: c.folder.appendingPathComponent(BridgedNetworkConfig.fileName).path)
    }

    static func load(_ c: VMConfig) throws -> BridgedNetworkConfig? {
        let file = c.folder.appendingPathComponent(BridgedNetworkConfig.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try BridgedNetworkConfig(text: String(contentsOf: file, encoding: .utf8))
    }

    struct Unavailable: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    static func prepare(_ c: VMConfig) throws -> BridgedNetworkConfig? {
        guard let choice = try load(c) else { return nil }
        guard (try? String(contentsOf: c.folder.appendingPathComponent("bridged-network-ready"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) == "1" else {
            throw Unavailable(reason: "Start this VM on shared networking and configure Bridged network once to prepare its private management link.")
        }
        guard let status = FastNetwork.runScript(
            ["--status", "--bridged-interface", choice.interface, "--app", Bundle.main.bundlePath], gui: false),
              status.status == 0, status.out.split(separator: "\n").first == "ok" else {
            throw Unavailable(reason: "The bridged network on \(choice.interface) is not ready. Configure it under Network before starting the VM. The VM was not switched to shared networking.")
        }
        return choice
    }

    static func interfaces() -> (names: [String], error: String?) {
        guard let result = FastNetwork.runScript(["--interfaces", "--app", Bundle.main.bundlePath], gui: false) else {
            return ([], "This app has no bridged network installer.")
        }
        guard result.status == 0 else { return ([], message(result.err, status: result.status)) }
        let names = result.out.split(whereSeparator: \.isNewline).map(String.init).filter {
            $0.range(of: "^en[0-9]{1,4}$", options: .regularExpression) != nil
        }
        return (names, nil)
    }

    static func set(_ c: VMConfig, interface: String?) -> String? {
        let command = Paths.resources.appendingPathComponent("omacvm/omacvm")
        guard FileManager.default.isExecutableFile(atPath: command.path) else {
            return "This app has no network configuration command."
        }
        let process = Process()
        process.executableURL = command
        process.arguments = ["network", "--vm", c.name, "--vm-dir", c.folder.path, "--json", "--yes"]
            + (interface.map { ["bridged", "--interface", $0] } ?? ["shared"])
        var environment = ProcessInfo.processInfo.environment
        environment["OMACVM_ADMIN_PROMPT"] = "gui"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { return error.localizedDescription }
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) { _ = output.fileHandleForReading.readDataToEndOfFile() }
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        return message(String(decoding: errorData, as: UTF8.self), status: process.terminationStatus)
    }

    private static func message(_ text: String, status: Int32) -> String {
        return text.split(whereSeparator: \.isNewline).last.map(String.init)
            ?? "The network configuration failed (\(status))."
    }
}
