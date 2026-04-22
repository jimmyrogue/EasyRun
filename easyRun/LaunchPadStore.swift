import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class LaunchPadStore: ObservableObject {
    static let shared = LaunchPadStore()

    @Published var projects: [ManagedProject] = []
    @Published var devices: [RunDevice] = []
    @Published var xcodePath: String = ""
    @Published var globalMessage: String?
    @Published var isDropTargeted = false

    private var activeProcesses: [UUID: Process] = [:]
    private var runtimeLogProcesses: [UUID: Process] = [:]
    private let fileManager = FileManager.default
    private let maxLogCharacters = 250_000

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
        activeProcesses[removed.id]?.terminate()
        activeProcesses[removed.id] = nil

        var updatedProjects = projects
        updatedProjects.remove(at: index)
        projects = updatedProjects
        globalMessage = L10n.format("Message.ProjectRemovedFormat", removed.name)
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
        updateAndSave(id) { $0.scheme = value }
    }

    func updateConfiguration(_ id: UUID, value: String) {
        updateAndSave(id) { $0.configuration = value }
    }

    func updateBundleID(_ id: UUID, value: String) {
        updateAndSave(id) { $0.bundleID = value }
    }

    func updateDerivedDataPath(_ id: UUID, value: String) {
        updateAndSave(id) { $0.derivedDataPath = value }
    }

    func updateLogSearch(_ id: UUID, value: String) {
        updateProject(id) { $0.logSearch = value }
    }

    func selectDevice(projectID: UUID, deviceID: String) {
        guard let device = devices.first(where: { $0.id == deviceID }) else { return }
        updateAndSave(projectID) { project in
            project.deviceID = device.udid
            project.deviceName = device.name
            project.deviceKind = device.kind
            project.deviceRuntime = device.runtime
        }
    }

    func clearLogs(for project: ManagedProject) {
        updateProject(project.id) {
            $0.buildLog = ""
            $0.runtimeLog = ""
            $0.statusMessage = L10n.string("StatusMessage.LogsCleared")
        }
    }

    func copyLogs(for project: ManagedProject) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            """
            # \(project.name)

            ## \(L10n.string("Logs.Build"))
            \(project.buildLog)

            ## \(L10n.string("Logs.Runtime"))
            \(project.runtimeLog)
            """,
            forType: .string
        )
        globalMessage = L10n.format("Message.LogsCopiedFormat", project.name)
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
                try await bootSimulator(for: snapshot)
            }

            let buildSettings = try await showBuildSettings(for: snapshot)
            let bundleID = ProjectInspector.bundleIDFromBuildSettings(buildSettings.output) ?? snapshot.bundleID
            if bundleID != snapshot.bundleID {
                updateAndSave(snapshot.id) { $0.bundleID = bundleID }
            }

            _ = try await xcodebuildBuild(for: snapshot)
            let appURL = ProjectInspector.productPath(for: snapshot, output: buildSettings.output)

            updateProject(snapshot.id) {
                $0.status = .installing
                $0.statusMessage = L10n.format("StatusMessage.InstallingFormat", appURL.lastPathComponent)
            }

            switch snapshot.deviceKind {
            case .simulator:
                try await installOnSimulator(project: snapshot, appURL: appURL)
                updateProject(snapshot.id) {
                    $0.status = .launching
                    $0.statusMessage = L10n.format("StatusMessage.LaunchingFormat", bundleID)
                }
                try await launchOnSimulator(project: snapshot, bundleID: bundleID)
                startRuntimeLog(for: snapshot, bundleID: bundleID)
            case .physical:
                try await installOnDevice(project: snapshot, appURL: appURL)
                updateProject(snapshot.id) {
                    $0.status = .launching
                    $0.statusMessage = L10n.format("StatusMessage.LaunchingFormat", bundleID)
                }
                let pid = try await launchOnDevice(project: snapshot, bundleID: bundleID)
                updateAndSave(snapshot.id) { $0.lastDevicePID = pid }
            }

            let duration = Date().timeIntervalSince(start)
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
                $0.buildLog += "\n\(L10n.format("Log.CleanedPathFormat", project.resolvedDerivedDataURL.path))\n"
            }
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
        guard let match = firstErrorLocation(in: project.buildLog) else {
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
                "-derivedDataPath", project.resolvedDerivedDataURL.path
            ]

        return try await ShellCommand.run(
            "/usr/bin/xcodebuild",
            args,
            checkExit: false,
            onOutput: { [weak self] chunk in self?.appendBuildLog(project.id, chunk) }
        )
    }

    private func xcodebuildBuild(for project: ManagedProject) async throws -> ShellResult {
        let args = ["build"]
            + ProjectInspector.projectArguments(for: project)
            + [
                "-scheme", project.scheme,
                "-configuration", project.configuration,
                "-destination", ProjectInspector.destination(for: project),
                "-derivedDataPath", project.resolvedDerivedDataURL.path
            ]

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

    private func launchOnSimulator(project: ManagedProject, bundleID: String) async throws {
        _ = try await ShellCommand.run(
            "/usr/bin/xcrun",
            ["simctl", "launch", project.deviceID, bundleID],
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

    private func launchOnDevice(project: ManagedProject, bundleID: String) async throws -> Int? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("easyrun-launch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        _ = try await ShellCommand.run(
            "/usr/bin/xcrun",
            [
                "devicectl", "device", "process", "launch",
                "--device", project.deviceID,
                "--terminate-existing",
                "--json-output", outputURL.path,
                bundleID
            ],
            checkExit: true,
            onOutput: { [weak self] chunk in self?.appendBuildLog(project.id, chunk) }
        )

        return parsePID(from: outputURL)
    }

    private func startRuntimeLog(for project: ManagedProject, bundleID: String) {
        stopRuntimeLog(for: project.id)

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "simctl", "spawn", project.deviceID,
            "log", "stream",
            "--style", "compact",
            "--predicate", "subsystem == \"\(bundleID)\" OR processImagePath CONTAINS \"\(project.scheme)\""
        ]
        process.standardOutput = pipe
        process.standardError = pipe
        let projectID = project.id
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                LaunchPadStore.shared.appendRuntimeLog(projectID, chunk)
            }
        }

        do {
            try process.run()
            runtimeLogProcesses[project.id] = process
            appendRuntimeLog(project.id, L10n.format("Log.RuntimeAttachedFormat", bundleID) + "\n")
        } catch {
            appendRuntimeLog(project.id, L10n.format("Log.RuntimeFailedFormat", error.localizedDescription) + "\n")
        }
    }

    private func stopRuntimeLog(for id: UUID) {
        runtimeLogProcesses[id]?.terminate()
        runtimeLogProcesses[id] = nil
    }

    private func appendBuildLog(_ id: UUID, _ chunk: String) {
        appendLog(id, keyPath: \.buildLog, chunk: chunk)
    }

    private func appendRuntimeLog(_ id: UUID, _ chunk: String) {
        appendLog(id, keyPath: \.runtimeLog, chunk: chunk)
    }

    private func appendLog(_ id: UUID, keyPath: WritableKeyPath<ManagedProject, String>, chunk: String) {
        updateProject(id) { project in
            project[keyPath: keyPath] += chunk
            if project[keyPath: keyPath].count > maxLogCharacters {
                project[keyPath: keyPath].removeFirst(project[keyPath: keyPath].count - maxLogCharacters)
            }
        }
    }

    private func markFailed(_ id: UUID, message: String) {
        updateAndSave(id) {
            $0.status = .failed
            $0.statusMessage = message
            $0.isExpanded = true
            $0.buildLog += "\n\(message)\n"
        }
    }

    private func repairMissingDevices() {
        guard !devices.isEmpty else { return }
        var updatedProjects = projects
        for index in updatedProjects.indices {
            if let selected = devices.first(where: { $0.id == updatedProjects[index].deviceID }) {
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
            copy.logSearch = ""
            copy.isExpanded = false
            return copy
        }

        if filteredProjects.count != decoded.projects.count {
            globalMessage = L10n.format(
                "Message.IgnoredDependencyProjectsFormat",
                decoded.projects.count - filteredProjects.count
            )
            save()
        }
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
