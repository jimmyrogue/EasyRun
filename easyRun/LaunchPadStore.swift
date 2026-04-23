import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import UserNotifications

private enum BufferedLogKind: Hashable {
    case build
    case runtime
}

private struct BufferedLogKey: Hashable {
    var projectID: UUID
    var kind: BufferedLogKind
}

private struct BuildProductCacheKey: Hashable {
    var projectID: UUID
    var scheme: String
    var configuration: String
    var buildFolder: String
    var derivedDataPath: String

    init(project: ManagedProject) {
        projectID = project.id
        scheme = project.scheme
        configuration = project.configuration
        buildFolder = project.deviceKind == .simulator
            ? project.devicePlatform.simulatorBuildFolder
            : project.devicePlatform.physicalBuildFolder
        derivedDataPath = project.resolvedDerivedDataURL.path
    }
}

@MainActor
final class LaunchPadStore: ObservableObject {
    static let shared = LaunchPadStore()

    @Published var projects: [ManagedProject] = []
    @Published var devices: [RunDevice] = []
    @Published var xcodePath: String = ""
    @Published var globalMessage: String?
    @Published var isDropTargeted = false

    private var activeProcesses: [UUID: Process] = [:]
    private let runtimeLogs = RuntimeLogController()
    private var productInfoCache: [BuildProductCacheKey: BuildProductInfo] = [:]
    private var pendingLogBuffers: [BufferedLogKey: String] = [:]
    private var logFlushTasks: [BufferedLogKey: Task<Void, Never>] = [:]
    private let fileManager = FileManager.default
    private let maxLogCharacters = 80_000
    private let logFlushInterval: UInt64 = 400_000_000

    var isBusy: Bool {
        projects.contains { $0.status.isBusy }
    }

    var hasFailure: Bool {
        projects.contains { $0.status == .failed }
    }

    private init() {
        load()
        Task {
            await bootstrap()
        }
    }

    func bootstrap() async {
        await refreshXcodePath()
        await refreshDevices()
    }

    func refreshXcodePath() async {
        do {
            let result = try await ShellCommand.run("/usr/bin/xcode-select", ["-p"], checkExit: true)
            xcodePath = result.output.trimmed
        } catch {
            xcodePath = ""
            globalMessage = L10n.string("Message.XcodeToolsNotFound")
        }
    }

    func refreshDevices() async {
        devices = await DeviceScanner.scanDevices()
        repairMissingDevices()
    }

    func addProjects(from urls: [URL]) {
        Task {
            await refreshDevices()
            let projectURLs = resolveProjectURLs(from: urls)
            guard !projectURLs.isEmpty else {
                globalMessage = L10n.string("Message.NoProjectsFound")
                return
            }

            var addedCount = 0
            var skippedCount = 0

            for url in projectURLs {
                do {
                    var project = try await ProjectInspector.makeProject(from: url, devices: devices)
                    if projects.contains(where: { $0.path == project.path }) {
                        skippedCount += 1
                        continue
                    }
                    project.isExpanded = true
                    var updatedProjects = projects
                    updatedProjects.append(project)
                    projects = updatedProjects
                    addedCount += 1
                    save()
                } catch {
                    globalMessage = error.localizedDescription
                }
            }

            if addedCount > 0 {
                let skippedText = skippedCount > 0 ? " " + L10n.format("Message.DuplicatesSkippedFormat", skippedCount) : ""
                globalMessage = addedCount == 1
                    ? L10n.format("Message.ProjectAddedFormat", skippedText)
                    : L10n.format("Message.ProjectsAddedFormat", addedCount, skippedText)
            } else if skippedCount > 0 {
                globalMessage = L10n.string("Message.AllProjectsAlreadyAdded")
            }
        }
    }

    func showAddPanel() {
        let panel = NSOpenPanel()
        panel.title = L10n.string("Panel.ScanFolder.Title")
        panel.message = L10n.string("Panel.ScanFolder.Message")
        panel.prompt = L10n.string("Action.Scan")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowedContentTypes = [.folder]

        if panel.runModal() == .OK {
            addProjects(from: panel.urls)
        }
    }

    func remove(_ project: ManagedProject) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else {
            globalMessage = L10n.string("Message.ProjectNoLongerInList")
            return
        }

        let removed = projects[index]
        stopRuntimeLog(for: removed.id)
        discardBufferedLogs(for: removed.id)
        invalidateProductCache(for: removed.id)
        activeProcesses[removed.id]?.terminate()
        activeProcesses[removed.id] = nil

        var updatedProjects = projects
        updatedProjects.remove(at: index)
        projects = updatedProjects
        globalMessage = L10n.format("Message.ProjectRemovedFormat", removed.name)
        save()
    }

    func moveProjects(from source: IndexSet, to destination: Int) {
        let sourceIndexes = source.filter { projects.indices.contains($0) }.sorted()
        guard !sourceIndexes.isEmpty else { return }

        var updatedProjects = projects
        let movedProjects = sourceIndexes.map { updatedProjects[$0] }
        for index in sourceIndexes.reversed() {
            updatedProjects.remove(at: index)
        }

        let removedBeforeDestination = sourceIndexes.filter { $0 < destination }.count
        let insertionIndex = max(0, min(destination - removedBeforeDestination, updatedProjects.count))
        updatedProjects.insert(contentsOf: movedProjects, at: insertionIndex)

        projects = updatedProjects
        save()
    }

    func toggleExpanded(_ project: ManagedProject) {
        updateProject(project.id) { item in
            item.isExpanded.toggle()
        }
    }

    func updateName(_ id: UUID, value: String) {
        updateAndSave(id) { $0.name = value }
    }

    func updateScheme(_ id: UUID, value: String) {
        invalidateProductCache(for: id)
        updateAndSave(id) { $0.scheme = value }
    }

    func refreshSchemesIfNeeded(for id: UUID) async {
        guard let project = projects.first(where: { $0.id == id }),
              (project.schemes ?? []).isEmpty else {
            return
        }

        await refreshSchemes(for: project)
    }

    func refreshSchemes(for project: ManagedProject) async {
        do {
            let schemes = try await ProjectInspector.schemes(for: project)
            guard !schemes.isEmpty else { return }

            updateAndSave(project.id) { item in
                item.schemes = schemes
                if item.scheme.trimmed.isEmpty {
                    item.scheme = schemes[0]
                }
            }
        } catch {
            // Keep the existing scheme available. Some projects cannot be listed until dependencies are resolved.
        }
    }

    func updateConfiguration(_ id: UUID, value: String) {
        invalidateProductCache(for: id)
        updateAndSave(id) { $0.configuration = value }
    }

    func updateBundleID(_ id: UUID, value: String) {
        invalidateProductCache(for: id)
        updateAndSave(id) { $0.bundleID = value }
    }

    func updateDerivedDataPath(_ id: UUID, value: String) {
        invalidateProductCache(for: id)
        updateAndSave(id) { $0.derivedDataPath = value }
    }

    func updateLogSearch(_ id: UUID, value: String) {
        updateProject(id) { $0.logSearch = value }
    }

    func selectDevice(projectID: UUID, deviceID: String) {
        guard let device = devices.first(where: { $0.matches(deviceID) }) else { return }
        invalidateProductCache(for: projectID)
        updateAndSave(projectID) { project in
            project.deviceID = device.udid
            project.deviceName = device.name
            project.deviceKind = device.kind
            project.deviceRuntime = device.runtime
        }
    }

    func clearLogs(for project: ManagedProject) {
        discardBufferedLogs(for: project.id)
        updateProject(project.id) {
            $0.buildLog = ""
            $0.runtimeLog = ""
            $0.statusMessage = L10n.string("StatusMessage.LogsCleared")
        }
    }

    func copyLogs(for project: ManagedProject) {
        flushLogs(for: project.id)
        guard let currentProject = projects.first(where: { $0.id == project.id }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            """
            # \(currentProject.name)

            ## \(L10n.string("Logs.Build"))
            \(currentProject.buildLog)

            ## \(L10n.string("Logs.Runtime"))
            \(currentProject.runtimeLog)
            """,
            forType: .string
        )
        globalMessage = L10n.format("Message.LogsCopiedFormat", currentProject.name)
    }

    func run(_ project: ManagedProject) async {
        guard let snapshot = projects.first(where: { $0.id == project.id }) else { return }
        guard !snapshot.scheme.trimmed.isEmpty else {
            markFailed(snapshot.id, message: L10n.string("Error.SchemeRequired"))
            return
        }
        guard !snapshot.deviceID.trimmed.isEmpty else {
            markFailed(snapshot.id, message: L10n.string("Error.PickDeviceFirst"))
            return
        }

        let start = Date()
        let cacheKey = BuildProductCacheKey(project: snapshot)
        stopRuntimeLog(for: snapshot.id)

        updateProject(snapshot.id) {
            $0.status = .building
            $0.statusMessage = L10n.string("StatusMessage.StartingBuild")
            $0.buildLog = ""
            $0.runtimeLog = ""
            $0.lastDevicePID = nil
        }

        do {
            if snapshot.deviceKind == .simulator {
                try await timedPhase(L10n.string("RunPhase.BootSimulator"), projectID: snapshot.id) {
                    try await bootSimulator(for: snapshot)
                }
            }

            try await timedPhase(L10n.string("RunPhase.Build"), projectID: snapshot.id) {
                _ = try await xcodebuildBuild(for: snapshot)
                activeProcesses[snapshot.id] = nil
            }

            flushLogs(for: snapshot.id)

            let productInfo = try await timedPhase(L10n.string("RunPhase.ResolveProduct"), projectID: snapshot.id) {
                try await resolveBuildProduct(for: snapshot, cacheKey: cacheKey)
            }
            if productInfo.bundleID != snapshot.bundleID {
                updateAndSave(snapshot.id) { $0.bundleID = productInfo.bundleID }
            }

            updateProject(snapshot.id) {
                $0.status = .installing
                $0.statusMessage = L10n.format("StatusMessage.InstallingFormat", productInfo.appURL.lastPathComponent)
            }

            switch snapshot.deviceKind {
            case .simulator:
                try await timedPhase(L10n.string("RunPhase.Install"), projectID: snapshot.id) {
                    try await installOnSimulator(project: snapshot, appURL: productInfo.appURL)
                }
                updateProject(snapshot.id) {
                    $0.status = .launching
                    $0.statusMessage = L10n.format("StatusMessage.LaunchingFormat", productInfo.bundleID)
                }
                try await timedPhase(L10n.string("RunPhase.LaunchAttachLogs"), projectID: snapshot.id) {
                    try startSimulatorRuntimeLogs(project: snapshot, product: productInfo)
                }
            case .physical:
                try await timedPhase(L10n.string("RunPhase.Install"), projectID: snapshot.id) {
                    try await installOnDevice(project: snapshot, appURL: productInfo.appURL)
                }
                updateProject(snapshot.id) {
                    $0.status = .launching
                    $0.statusMessage = L10n.format("StatusMessage.LaunchingFormat", productInfo.bundleID)
                }
                try await timedPhase(L10n.string("RunPhase.LaunchAttachLogs"), projectID: snapshot.id) {
                    try startDeviceRuntimeLogs(project: snapshot, product: productInfo)
                }
            }

            let duration = Date().timeIntervalSince(start)
            flushLogs(for: snapshot.id)
            updateAndSave(snapshot.id) {
                $0.status = .running
                $0.statusMessage = L10n.format("StatusMessage.LaunchedInFormat", duration)
                $0.lastRunAt = Date()
                $0.lastRunDuration = duration
            }
            notify(
                title: L10n.format("Notification.LaunchedTitleFormat", snapshot.name),
                body: L10n.format("Notification.FinishedInFormat", duration)
            )
        } catch {
            activeProcesses[snapshot.id]?.terminate()
            activeProcesses[snapshot.id] = nil
            flushLogs(for: snapshot.id)
            let message = error.localizedDescription
            markFailed(snapshot.id, message: message)
            notify(
                title: L10n.string("Notification.BuildFailedTitle"),
                body: L10n.format("Notification.BuildFailedBodyFormat", snapshot.name)
            )
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func stop(_ project: ManagedProject) async {
        activeProcesses[project.id]?.terminate()
        activeProcesses[project.id] = nil
        stopRuntimeLog(for: project.id)
        flushLogs(for: project.id)

        updateProject(project.id) {
            $0.status = .stopping
            $0.statusMessage = L10n.string("StatusMessage.StoppingApp")
        }

        do {
            switch project.deviceKind {
            case .simulator:
                _ = try await ShellCommand.run(
                    "/usr/bin/xcrun",
                    ["simctl", "terminate", project.deviceID, project.bundleID],
                    checkExit: false,
                    onOutput: { [weak self] chunk in
                        self?.appendRuntimeLog(project.id, chunk)
                    }
                )
            case .physical:
                if let pid = project.lastDevicePID {
                    _ = try await ShellCommand.run(
                        "/usr/bin/xcrun",
                        ["devicectl", "device", "process", "terminate", "--device", project.deviceID, "--pid", "\(pid)"],
                        checkExit: false,
                        onOutput: { [weak self] chunk in
                            self?.appendRuntimeLog(project.id, chunk)
                        }
                    )
                } else {
                    appendRuntimeLog(project.id, L10n.string("Log.PhysicalStopNeedsPID") + "\n")
                }
            }

            updateAndSave(project.id) {
                $0.status = .stopped
                $0.statusMessage = L10n.string("Status.Stopped")
            }
        } catch {
            markFailed(project.id, message: error.localizedDescription)
        }
    }

    func clean(_ project: ManagedProject) async {
        activeProcesses[project.id]?.terminate()
        activeProcesses[project.id] = nil
        stopRuntimeLog(for: project.id)
        flushLogs(for: project.id)
        invalidateProductCache(for: project.id)

        updateProject(project.id) {
            $0.status = .cleaning
            $0.statusMessage = L10n.string("StatusMessage.RemovingDerivedData")
        }

        do {
            guard isSafeDerivedDataPath(project.resolvedDerivedDataURL) else {
                throw NSError(
                    domain: "LaunchPadStore",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey: L10n.string("Error.RefusingUnsafeClean")
                    ]
                )
            }

            try? fileManager.createDirectory(
                at: project.resolvedDerivedDataURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: project.resolvedDerivedDataURL.path) {
                try fileManager.removeItem(at: project.resolvedDerivedDataURL)
            }

            updateAndSave(project.id) {
                $0.status = .idle
                $0.statusMessage = L10n.string("StatusMessage.DerivedDataCleaned")
            }
            appendBuildLog(project.id, "\n\(L10n.format("Log.CleanedPathFormat", project.resolvedDerivedDataURL.path))\n")
            flushLog(BufferedLogKey(projectID: project.id, kind: .build))
        } catch {
            markFailed(project.id, message: error.localizedDescription)
        }
    }

    private func isSafeDerivedDataPath(_ url: URL) -> Bool {
        guard let derivedDataRoot = fileManager
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Developer/Xcode/DerivedData", isDirectory: true)
            .standardizedFileURL else {
            return false
        }

        let cleanURL = url.standardizedFileURL
        return cleanURL.path.hasPrefix(derivedDataRoot.path + "/")
            && cleanURL.lastPathComponent.hasPrefix("LaunchPad-")
    }

    func openFirstError(for project: ManagedProject) {
        flushLogs(for: project.id)
        guard let currentProject = projects.first(where: { $0.id == project.id }),
              let match = firstErrorLocation(in: currentProject.buildLog) else {
            globalMessage = L10n.string("Message.NoSourceErrorLocation")
            return
        }

        Task {
            _ = try? await ShellCommand.run(
                "/usr/bin/xed",
                ["-l", "\(match.line)", match.file],
                checkExit: false
            )
        }
    }

    private func timedPhase<T>(
        _ name: String,
        projectID: UUID,
        operation: () async throws -> T
    ) async throws -> T {
        let startedAt = Date()
        appendBuildLog(projectID, L10n.format("Log.PhaseStartedFormat", name) + "\n")
        do {
            let result = try await operation()
            let timing = RunPhaseTiming(name: name, startedAt: startedAt, endedAt: Date())
            appendBuildLog(projectID, L10n.format("Log.PhaseFinishedFormat", timing.duration, timing.name) + "\n")
            return result
        } catch {
            let timing = RunPhaseTiming(name: name, startedAt: startedAt, endedAt: Date())
            appendBuildLog(projectID, L10n.format("Log.PhaseFailedFormat", timing.duration, timing.name) + "\n")
            throw error
        }
    }

    private func resolveBuildProduct(for project: ManagedProject, cacheKey: BuildProductCacheKey) async throws -> BuildProductInfo {
        do {
            let info = try await BuildProductResolver.resolve(project: project, cached: productInfoCache[cacheKey])
            productInfoCache[cacheKey] = info
            appendBuildLog(project.id, L10n.format("Log.ProductResolvedFormat", info.appURL.path, info.bundleID, info.executableName) + "\n")
            return info
        } catch {
            appendBuildLog(project.id, L10n.format("Log.ProductResolverFallbackFormat", error.localizedDescription) + "\n")
            let buildSettings = try await showBuildSettings(for: project)
            let appURL = ProjectInspector.productPath(for: project, output: buildSettings.output)
            let fallbackBundleID = ProjectInspector.bundleIDFromBuildSettings(buildSettings.output) ?? project.bundleID
            var info = try BuildProductResolver.info(
                for: appURL,
                buildFolder: buildFolder(for: project),
                fallbackBundleID: fallbackBundleID
            )
            if let executableName = ProjectInspector.executableNameFromBuildSettings(buildSettings.output),
               !executableName.isEmpty {
                info.executableName = executableName
            }
            productInfoCache[cacheKey] = info
            appendBuildLog(project.id, L10n.format("Log.ProductResolvedFormat", info.appURL.path, info.bundleID, info.executableName) + "\n")
            return info
        }
    }

    private func buildFolder(for project: ManagedProject) -> String {
        project.deviceKind == .simulator
            ? project.devicePlatform.simulatorBuildFolder
            : project.devicePlatform.physicalBuildFolder
    }

    private func startSimulatorRuntimeLogs(project: ManagedProject, product: BuildProductInfo) throws {
        try runtimeLogs.startSimulatorLogs(
            project: project,
            product: product,
            onOutput: { [weak self] chunk in
                self?.appendRuntimeLog(project.id, chunk)
            }
        )
    }

    private func startDeviceRuntimeLogs(project: ManagedProject, product: BuildProductInfo) throws {
        try runtimeLogs.startDeviceConsole(
            project: project,
            product: product,
            onOutput: { [weak self] chunk in
                self?.appendRuntimeLog(project.id, chunk)
            },
            onJSONOutputReady: { [weak self] outputURL in
                self?.scheduleDevicePIDRead(projectID: project.id, outputURL: outputURL)
            }
        )
    }

    private func scheduleDevicePIDRead(projectID: UUID, outputURL: URL) {
        Task { @MainActor [weak self] in
            let delays: [UInt64] = [300_000_000, 1_000_000_000, 2_000_000_000]
            for delay in delays {
                try? await Task.sleep(nanoseconds: delay)
                guard let self else { return }
                if let pid = self.parsePID(from: outputURL) {
                    self.updateAndSave(projectID) { $0.lastDevicePID = pid }
                    self.appendRuntimeLog(projectID, L10n.format("Log.DevicePIDFormat", pid) + "\n")
                    return
                }
            }
        }
    }

    private func bootSimulator(for project: ManagedProject) async throws {
        updateProject(project.id) {
            $0.status = .launching
            $0.statusMessage = L10n.format("StatusMessage.BootingFormat", project.deviceName)
        }

        _ = try await ShellCommand.run(
            "/usr/bin/xcrun",
            ["simctl", "boot", project.deviceID],
            checkExit: false,
            onOutput: { [weak self] chunk in self?.appendBuildLog(project.id, chunk) }
        )
        _ = try await ShellCommand.run("/usr/bin/open", ["-a", "Simulator"], checkExit: false)
        _ = try await ShellCommand.run(
            "/usr/bin/xcrun",
            ["simctl", "bootstatus", project.deviceID, "-b"],
            checkExit: false,
            onOutput: { [weak self] chunk in self?.appendBuildLog(project.id, chunk) }
        )
    }

    private func showBuildSettings(for project: ManagedProject) async throws -> ShellResult {
        let args = ["-showBuildSettings"]
            + ProjectInspector.projectArguments(for: project)
            + [
                "-scheme", project.scheme,
                "-configuration", project.configuration,
                "-destination", ProjectInspector.destination(for: project),
                "-destination-timeout", "10",
                "-derivedDataPath", project.resolvedDerivedDataURL.path
            ]

        return try await ShellCommand.run(
            "/usr/bin/xcodebuild",
            args,
            checkExit: true
        )
    }

    private func xcodebuildBuild(for project: ManagedProject) async throws -> ShellResult {
        var args = ["build"]
            + ProjectInspector.projectArguments(for: project)
            + [
                "-scheme", project.scheme,
                "-configuration", project.configuration,
                "-destination", ProjectInspector.destination(for: project),
                "-destination-timeout", "10",
                "-derivedDataPath", project.resolvedDerivedDataURL.path,
                "-parallelizeTargets",
                "-showBuildTimingSummary"
            ]
        if project.configuration.caseInsensitiveCompare("Debug") == .orderedSame {
            args.append("ONLY_ACTIVE_ARCH=YES")
        }

        return try await ShellCommand.run(
            "/usr/bin/xcodebuild",
            args,
            checkExit: true,
            onLaunch: { [weak self] process in
                Task { @MainActor in self?.activeProcesses[project.id] = process }
            },
            onOutput: { [weak self] chunk in self?.appendBuildLog(project.id, chunk) }
        )
    }

    private func installOnSimulator(project: ManagedProject, appURL: URL) async throws {
        _ = try await ShellCommand.run(
            "/usr/bin/xcrun",
            ["simctl", "install", project.deviceID, appURL.path],
            checkExit: true,
            onOutput: { [weak self] chunk in self?.appendBuildLog(project.id, chunk) }
        )
    }

    private func installOnDevice(project: ManagedProject, appURL: URL) async throws {
        _ = try await ShellCommand.run(
            "/usr/bin/xcrun",
            ["devicectl", "device", "install", "app", "--device", project.deviceID, appURL.path],
            checkExit: true,
            onOutput: { [weak self] chunk in self?.appendBuildLog(project.id, chunk) }
        )
    }

    private func stopRuntimeLog(for id: UUID) {
        runtimeLogs.stop(projectID: id)
        flushLog(BufferedLogKey(projectID: id, kind: .runtime))
    }

    private func appendBuildLog(_ id: UUID, _ chunk: String) {
        enqueueLog(id, kind: .build, chunk: chunk)
    }

    private func appendRuntimeLog(_ id: UUID, _ chunk: String) {
        enqueueLog(id, kind: .runtime, chunk: chunk)
    }

    private func enqueueLog(_ id: UUID, kind: BufferedLogKind, chunk: String) {
        guard !chunk.isEmpty else { return }

        let key = BufferedLogKey(projectID: id, kind: kind)
        pendingLogBuffers[key, default: ""] += chunk

        guard logFlushTasks[key] == nil else { return }
        let delay = logFlushInterval
        logFlushTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            self?.flushLog(key)
        }
    }

    private func flushLogs(for id: UUID) {
        flushLog(BufferedLogKey(projectID: id, kind: .build))
        flushLog(BufferedLogKey(projectID: id, kind: .runtime))
    }

    private func flushLog(_ key: BufferedLogKey) {
        logFlushTasks[key]?.cancel()
        logFlushTasks[key] = nil

        guard let chunk = pendingLogBuffers.removeValue(forKey: key), !chunk.isEmpty else { return }
        switch key.kind {
        case .build:
            appendLogNow(key.projectID, keyPath: \.buildLog, chunk: chunk)
        case .runtime:
            appendLogNow(key.projectID, keyPath: \.runtimeLog, chunk: chunk)
        }
    }

    private func discardBufferedLogs(for id: UUID) {
        let keys = Set(pendingLogBuffers.keys).union(logFlushTasks.keys).filter { $0.projectID == id }
        for key in keys {
            logFlushTasks[key]?.cancel()
            logFlushTasks[key] = nil
            pendingLogBuffers[key] = nil
        }
    }

    private func invalidateProductCache(for id: UUID) {
        for key in productInfoCache.keys where key.projectID == id {
            productInfoCache[key] = nil
        }
    }

    private func appendLogNow(_ id: UUID, keyPath: WritableKeyPath<ManagedProject, String>, chunk: String) {
        updateProject(id) { project in
            project[keyPath: keyPath].append(chunk)
            project[keyPath: keyPath] = limitedLog(project[keyPath: keyPath])
        }
    }

    private func markFailed(_ id: UUID, message: String) {
        updateAndSave(id) {
            $0.status = .failed
            $0.statusMessage = message
            $0.isExpanded = true
        }
        appendBuildLog(id, "\n\(message)\n")
        flushLog(BufferedLogKey(projectID: id, kind: .build))
    }

    private func limitedLog(_ value: String) -> String {
        guard value.count > maxLogCharacters else { return value }
        return String(value.suffix(maxLogCharacters))
    }

    private func repairMissingDevices() {
        guard !devices.isEmpty else { return }
        var updatedProjects = projects
        for index in updatedProjects.indices {
            if let selected = devices.first(where: { $0.matches(updatedProjects[index].deviceID) }) {
                updatedProjects[index].deviceID = selected.udid
                updatedProjects[index].deviceName = selected.name
                updatedProjects[index].deviceKind = selected.kind
                updatedProjects[index].deviceRuntime = selected.runtime
                continue
            }

            guard let preferred = DeviceScanner.preferredDevice(from: devices) else { continue }
            updatedProjects[index].deviceID = preferred.udid
            updatedProjects[index].deviceName = preferred.name
            updatedProjects[index].deviceKind = preferred.kind
            updatedProjects[index].deviceRuntime = preferred.runtime
        }
        projects = updatedProjects
        save()
    }

    private func resolveProjectURLs(from urls: [URL]) -> [URL] {
        var discovered: [URL] = []
        var seen = Set<String>()

        for url in urls {
            for projectURL in projectURLs(under: url) {
                let key = projectURL.standardizedFileURL.path
                guard seen.insert(key).inserted else { continue }
                discovered.append(projectURL)
            }
        }

        return preferWorkspaces(overSiblingProjects: discovered).sorted {
            if $0.pathExtension != $1.pathExtension {
                return $0.pathExtension == "xcworkspace"
            }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private func projectURLs(under url: URL) -> [URL] {
        let cleanURL = url.standardizedFileURL
        if isXcodeProjectContainer(cleanURL) {
            return isDependencyProjectContainer(cleanURL) ? [] : [cleanURL]
        }

        guard (try? cleanURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let enumerator = fileManager.enumerator(
                at: cleanURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return []
        }

        var urls: [URL] = []
        for case let itemURL as URL in enumerator {
            let projectURL = itemURL.standardizedFileURL

            if shouldSkipScanning(projectURL) {
                enumerator.skipDescendants()
                continue
            }

            guard isXcodeProjectContainer(projectURL) else { continue }
            guard !isDependencyProjectContainer(projectURL) else {
                enumerator.skipDescendants()
                continue
            }

            urls.append(projectURL)
            enumerator.skipDescendants()
        }
        return urls
    }

    private func preferWorkspaces(overSiblingProjects urls: [URL]) -> [URL] {
        let workspaceFolders = Set(
            urls
                .filter { $0.pathExtension == "xcworkspace" }
                .map { $0.deletingLastPathComponent().standardizedFileURL.path }
        )

        return urls.filter { url in
            url.pathExtension == "xcworkspace"
                || !workspaceFolders.contains(url.deletingLastPathComponent().standardizedFileURL.path)
        }
    }

    private func isXcodeProjectContainer(_ url: URL) -> Bool {
        ["xcodeproj", "xcworkspace"].contains(url.pathExtension)
    }

    private func shouldSkipScanning(_ url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return false
        }

        return [
            ".build",
            "build",
            "Carthage",
            "DerivedData",
            "node_modules",
            "Pods",
            "SourcePackages"
        ].contains(url.lastPathComponent)
    }

    private func isDependencyProjectContainer(_ url: URL) -> Bool {
        let dependencyFolders = Set(["Carthage", "Pods", "SourcePackages"])
        return url.pathComponents.contains { dependencyFolders.contains($0) }
    }

    private func updateProject(_ id: UUID, mutate: (inout ManagedProject) -> Void) {
        var updatedProjects = projects
        guard let index = updatedProjects.firstIndex(where: { $0.id == id }) else { return }
        mutate(&updatedProjects[index])
        projects = updatedProjects
    }

    private func updateAndSave(_ id: UUID, mutate: (inout ManagedProject) -> Void) {
        updateProject(id, mutate: mutate)
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: persistenceURL),
              let decoded = try? JSONDecoder.projectStore.decode(PersistedProjects.self, from: data) else {
            return
        }

        let filteredProjects = decoded.projects.filter {
            !isDependencyProjectContainer(URL(fileURLWithPath: $0.path))
        }

        projects = filteredProjects.map { project in
            var copy = project
            copy.status = .idle
            copy.statusMessage = L10n.string("StatusMessage.Ready")
            copy.buildLog = ""
            copy.runtimeLog = ""
            copy.logSearch = ""
            copy.isExpanded = false
            copy.lastDevicePID = nil
            return copy
        }

        if filteredProjects.count != decoded.projects.count {
            globalMessage = L10n.format(
                "Message.IgnoredDependencyProjectsFormat",
                decoded.projects.count - filteredProjects.count
            )
        }
        save()
    }

    private func save() {
        do {
            try fileManager.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.pretty.encode(PersistedProjects(projects: projects))
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            globalMessage = L10n.format("Message.CouldNotSaveProjectsFormat", error.localizedDescription)
        }
    }

    private var persistenceURL: URL {
        fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("LaunchPadiOS", isDirectory: true)
            .appendingPathComponent("projects.json")
    }

    private func firstErrorLocation(in log: String) -> (file: String, line: Int)? {
        let pattern = #"(/.*?):(\d+):\d+:\s+error:"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: log, range: NSRange(log.startIndex..., in: log)),
              let fileRange = Range(match.range(at: 1), in: log),
              let lineRange = Range(match.range(at: 2), in: log),
              let line = Int(log[lineRange]) else {
            return nil
        }
        return (String(log[fileRange]), line)
    }

    private func parsePID(from outputURL: URL) -> Int? {
        guard let data = try? Data(contentsOf: outputURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return findPID(in: object)
    }

    private func findPID(in object: Any) -> Int? {
        if let dictionary = object as? [String: Any] {
            for key in ["processIdentifier", "pid", "processID"] {
                if let value = dictionary[key] as? Int { return value }
                if let value = dictionary[key] as? String, let pid = Int(value) { return pid }
            }
            for value in dictionary.values {
                if let pid = findPID(in: value) { return pid }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let pid = findPID(in: value) { return pid }
            }
        }
        return nil
    }

    private func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var projectStore: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
