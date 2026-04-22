import Foundation

struct ShellResult {
    var exitCode: Int32
    var output: String
}

enum ShellCommandError: LocalizedError {
    case launchFailed(String)
    case nonZeroExit(command: String, exitCode: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return message
        case .nonZeroExit(let command, let exitCode, let output):
            let tail = output
                .split(separator: "\n")
                .suffix(18)
                .joined(separator: "\n")
            return L10n.format("Error.CommandFailedFormat", command, Int(exitCode), tail)
        }
    }
}

enum ShellCommand {
    static func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        checkExit: Bool = true,
        onLaunch: ((Process) -> Void)? = nil,
        onOutput: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            let state = ShellCommandState()

            @Sendable func append(_ chunk: String) {
                state.append(chunk)
                Task { @MainActor in
                    onOutput(chunk)
                }
            }

            @Sendable func resume(_ result: Result<ShellResult, Error>) {
                guard state.markResumed() else { return }
                switch result {
                case .success(let shellResult):
                    continuation.resume(returning: shellResult)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectory

            if let environment {
                var merged = ProcessInfo.processInfo.environment
                environment.forEach { merged[$0.key] = $0.value }
                process.environment = merged
            }

            process.standardOutput = pipe
            process.standardError = pipe

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let chunk = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                append(chunk)
            }

            process.terminationHandler = { terminatedProcess in
                pipe.fileHandleForReading.readabilityHandler = nil
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if !data.isEmpty {
                    append(String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self))
                }

                let capturedOutput = state.snapshot()

                let result = ShellResult(exitCode: terminatedProcess.terminationStatus, output: capturedOutput)
                if checkExit && result.exitCode != 0 {
                    let command = ([executable] + arguments).joined(separator: " ")
                    resume(.failure(ShellCommandError.nonZeroExit(
                        command: command,
                        exitCode: result.exitCode,
                        output: result.output
                    )))
                } else {
                    resume(.success(result))
                }
            }

            do {
                try process.run()
                onLaunch?(process)
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                resume(.failure(ShellCommandError.launchFailed(error.localizedDescription)))
            }
        }
    }
}

private final class ShellCommandState: @unchecked Sendable {
    private let lock = NSLock()
    private var output = ""
    private var didResume = false

    func append(_ chunk: String) {
        lock.lock()
        output += chunk
        lock.unlock()
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return output
    }

    func markResumed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        didResume = true
        return true
    }
}
