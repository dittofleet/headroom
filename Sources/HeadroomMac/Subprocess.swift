import Foundation

enum Subprocess {
    /// stdout of a short-lived command, or nil on failure or timeout.
    /// `input`, when given, is written to its stdin and then closed.
    static func run(_ path: String, _ args: [String], input: Data? = nil, timeout: TimeInterval = 5) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = FileHandle.nullDevice
                let stdin = input.map { _ in Pipe() }
                process.standardInput = stdin ?? FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                if let stdin, let input {
                    // On its own queue, so a child that talks before it has
                    // read everything cannot deadlock against us.
                    DispatchQueue.global(qos: .utility).async {
                        try? stdin.fileHandleForWriting.write(contentsOf: input)
                        try? stdin.fileHandleForWriting.close()
                    }
                }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                continuation.resume(returning: process.terminationStatus == 0 ? data : nil)
            }
        }
    }
}
