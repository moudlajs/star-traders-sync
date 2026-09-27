import Foundation

public struct CommandResult {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var ok: Bool { status == 0 }
    /// stdout then stderr, for showing a failure to a human.
    public var combined: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Runs processes with the environment a login shell would have.
///
/// An app launched from Finder inherits launchd's minimal PATH, which has
/// neither ~/bin nor Homebrew. Every child gets a PATH that does, so `sts`
/// finds a Homebrew tailscale exactly as it does from Terminal.
public enum Shell {
    public static func searchPath(home: String = NSHomeDirectory()) -> String {
        ["\(home)/bin", "/opt/homebrew/bin", "/usr/local/bin",
         "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
    }

    public static func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath()
        for (k, v) in extra { env[k] = v }
        return env
    }

    /// Runs to completion and captures both streams.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String],
                           env extra: [String: String] = [:],
                           stdin input: Data? = nil) -> CommandResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.environment = environment(extra)

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe = Pipe()
        p.standardInput = input == nil ? FileHandle.nullDevice : inPipe

        do { try p.run() } catch {
            return CommandResult(status: 127, stdout: "",
                                 stderr: "could not start \(executable): \(error.localizedDescription)")
        }
        if let input {
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
        }

        // Drain both pipes concurrently: a child that fills one while we
        // block on the other would deadlock.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave()
        }
        errData = err.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()

        return CommandResult(status: p.terminationStatus,
                             stdout: String(decoding: outData, as: UTF8.self)
                                 .trimmingCharacters(in: .whitespacesAndNewlines),
                             stderr: String(decoding: errData, as: UTF8.self)
                                 .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Runs to completion, handing every output line (stdout and stderr
    /// interleaved) to `onLine` as it arrives. Returns the exit status.
    public static func stream(_ executable: String, _ arguments: [String],
                              env extra: [String: String] = [:],
                              onLine: @escaping (String) -> Void) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.environment = environment(extra)
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        do { try p.run() } catch {
            onLine("could not start \(executable): \(error.localizedDescription)")
            return 127
        }

        var buffer = Data()
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                onLine(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...nl)
            }
        }
        if !buffer.isEmpty { onLine(String(decoding: buffer, as: UTF8.self)) }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
