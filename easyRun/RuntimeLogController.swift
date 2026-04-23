import Foundation

enum RuntimeLogMode {
    case simulatorConsole
    case simulatorUnifiedLog
    case deviceConsole
    case unavailable

    var label: String {
        switch self {
        case .simulatorConsole: return L10n.string("RuntimeLogMode.SimulatorConsole")
        case .simulatorUnifiedLog: return L10n.string("RuntimeLogMode.SimulatorUnifiedLog")
        case .deviceConsole: return L10n.string("RuntimeLogMode.DeviceConsole")
        case .unavailable: return L10n.string("RuntimeLogMode.Unavailable")
        }
    }
}

@MainActor
final class RuntimeLogController {
    private struct RuntimeLogHandle {
        var process: Process
        var cleanup: (() -> Void)?
    }

    private var handles: [UUID: [RuntimeLogHandle]] = [:]

    func stop(projectID: UUID) {
        handles[projectID]?.forEach { handle in
            if handle.process.isRunning {
                handle.process.terminate()
            }
            handle.cleanup?()
        }
        handles[projectID] = nil
    }

    func startSimulatorLogs(
        project: ManagedProject,
        product: BuildProductInfo,
        onOutput: @escaping @MainActor (String) -> Void
    ) throws {
        stop(projectID: project.id)
        try startSimulatorConsole(project: project, product: product, onOutput: onOutput)
        do {
            try startSimulatorUnifiedLog(project: project, product: product, onOutput: onOutput)
        } catch {
            onOutput(L10n.format("Log.RuntimeFailedFormat", error.localizedDescription) + "\n")
        }
    }

    func startDeviceConsole(
        project: ManagedProject,
        product: BuildProductInfo,
        onOutput: @escaping @MainActor (String) -> Void,
        onJSONOutputReady: @escaping @MainActor (URL) -> Void
    ) throws {
        stop(projectID: project.id)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("easyrun-launch-\(UUID().uuidString).json")
        let mode = RuntimeLogMode.deviceConsole
        let process = try ShellCommand.startStreaming(
            "/usr/bin/xcrun",
            [
                "devicectl", "device", "process", "launch",
                "--console",
                "--terminate-existing",
                "--device", project.deviceID,
                "--json-output", outputURL.path,
                product.bundleID
            ],
            environment: ["DEVICECTL_CHILD_OS_ACTIVITY_DT_MODE": "enable"],
            onOutput: onOutput,
            onTermination: { status in
                onOutput(L10n.format("Log.RuntimeProcessExitedFormat", mode.label, Int(status)) + "\n")
                onJSONOutputReady(outputURL)
                try? FileManager.default.removeItem(at: outputURL)
            }
        )

        appendHandle(process, for: project.id, cleanup: {
            try? FileManager.default.removeItem(at: outputURL)
        })
        onOutput(L10n.format("Log.RuntimeAttachedFormat", mode.label) + "\n")
        onJSONOutputReady(outputURL)
    }

    private func startSimulatorConsole(
        project: ManagedProject,
        product: BuildProductInfo,
        onOutput: @escaping @MainActor (String) -> Void
    ) throws {
        let mode = RuntimeLogMode.simulatorConsole
        let process = try ShellCommand.startStreaming(
            "/usr/bin/xcrun",
            [
                "simctl", "launch",
                "--console-pty",
                "--terminate-running-process",
                project.deviceID,
                product.bundleID
            ],
            environment: ["SIMCTL_CHILD_OS_ACTIVITY_DT_MODE": "enable"],
            onOutput: onOutput,
            onTermination: { status in
                onOutput(L10n.format("Log.RuntimeProcessExitedFormat", mode.label, Int(status)) + "\n")
            }
        )

        appendHandle(process, for: project.id)
        onOutput(L10n.format("Log.RuntimeAttachedFormat", mode.label) + "\n")
    }

    private func startSimulatorUnifiedLog(
        project: ManagedProject,
        product: BuildProductInfo,
        onOutput: @escaping @MainActor (String) -> Void
    ) throws {
        let mode = RuntimeLogMode.simulatorUnifiedLog
        let predicate = logPredicate(bundleID: product.bundleID, executableName: product.executableName)
        let process = try ShellCommand.startStreaming(
            "/usr/bin/xcrun",
            [
                "simctl", "spawn", project.deviceID,
                "log", "stream",
                "--predicate", predicate,
                "--level", "debug",
                "--style", "compact"
            ],
            onOutput: onOutput,
            onTermination: { status in
                onOutput(L10n.format("Log.RuntimeProcessExitedFormat", mode.label, Int(status)) + "\n")
            }
        )

        appendHandle(process, for: project.id)
        onOutput(L10n.format("Log.RuntimeAttachedFormat", mode.label) + "\n")
    }

    private func appendHandle(_ process: Process, for projectID: UUID, cleanup: (() -> Void)? = nil) {
        handles[projectID, default: []].append(RuntimeLogHandle(process: process, cleanup: cleanup))
    }

    private func logPredicate(bundleID: String, executableName: String) -> String {
        let escapedBundleID = predicateValue(bundleID)
        let escapedExecutableName = predicateValue(executableName)
        return """
        subsystem BEGINSWITH "\(escapedBundleID)" OR process == "\(escapedExecutableName)" OR processImagePath CONTAINS "\(escapedExecutableName)" OR senderImagePath CONTAINS "\(escapedExecutableName)"
        """
    }

    private func predicateValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
