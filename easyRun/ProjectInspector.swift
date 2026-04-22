import Foundation

enum ProjectInspector {
    static func makeProject(from url: URL, devices: [RunDevice]) async throws -> ManagedProject {
        let kind = try kind(for: url)
        let list = try await xcodeList(path: url.path, kind: kind)
        let schemes = list.project?.schemes ?? list.workspace?.schemes ?? []
        let scheme = schemes.first ?? url.deletingPathExtension().lastPathComponent
        let configuration = list.project?.configurations?.first { $0 == "Debug" } ?? "Debug"
        let bundleID = await bundleIdentifier(path: url.path, kind: kind, scheme: scheme, configuration: configuration)
        let device = DeviceScanner.preferredDevice(from: devices)

        return ManagedProject(
            name: defaultName(for: url),
            path: url.path,
            kind: kind,
            scheme: scheme,
            configuration: configuration,
            deviceID: device?.udid ?? "",
            deviceName: device?.name ?? "No device",
            deviceKind: device?.kind ?? .simulator,
            deviceRuntime: device?.runtime,
            bundleID: bundleID,
            derivedDataPath: defaultDerivedDataPath(for: url, scheme: scheme),
            statusMessage: "Imported \(scheme)"
        )
    }

    static func projectArguments(for project: ManagedProject) -> [String] {
        [project.kind.xcodebuildFlag, project.path]
    }

    static func destination(for project: ManagedProject) -> String {
        switch project.deviceKind {
        case .simulator:
            return "platform=\(project.devicePlatform.simulatorDestination),id=\(project.deviceID)"
        case .physical:
            return "platform=\(project.devicePlatform.physicalDestination),id=\(project.deviceID)"
        }
    }

    static func productPath(for project: ManagedProject, output: String) -> URL {
        let settings = parseBuildSettings(output)
        if let builtProductsDir = settings["BUILT_PRODUCTS_DIR"],
           let productName = settings["FULL_PRODUCT_NAME"] {
            return URL(fileURLWithPath: builtProductsDir).appendingPathComponent(productName)
        }

        let buildFolder = project.deviceKind == .simulator
            ? project.devicePlatform.simulatorBuildFolder
            : project.devicePlatform.physicalBuildFolder
        let folder = "\(project.configuration)-\(buildFolder)"
        return project.resolvedDerivedDataURL
            .appendingPathComponent("Build/Products")
            .appendingPathComponent(folder)
            .appendingPathComponent("\(project.scheme).app")
    }

    static func bundleIDFromBuildSettings(_ output: String) -> String? {
        parseBuildSettings(output)["PRODUCT_BUNDLE_IDENTIFIER"]?.trimmed
    }

    private static func kind(for url: URL) throws -> ProjectKind {
        switch url.pathExtension {
        case "xcodeproj": return .project
        case "xcworkspace": return .workspace
        default:
            throw NSError(
                domain: "ProjectInspector",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Drop a .xcodeproj or .xcworkspace file."]
            )
        }
    }

    private static func xcodeList(path: String, kind: ProjectKind) async throws -> XcodeListResponse {
        let result = try await ShellCommand.run(
            "/usr/bin/xcodebuild",
            ["-list", "-json", kind.xcodebuildFlag, path],
            checkExit: true
        )
        let json = extractJSON(from: result.output)
        return try JSONDecoder().decode(XcodeListResponse.self, from: Data(json.utf8))
    }

    private static func bundleIdentifier(
        path: String,
        kind: ProjectKind,
        scheme: String,
        configuration: String
    ) async -> String {
        do {
            let result = try await ShellCommand.run(
                "/usr/bin/xcodebuild",
                ["-showBuildSettings", kind.xcodebuildFlag, path, "-scheme", scheme, "-configuration", configuration],
                checkExit: false
            )
            if let bundleID = bundleIDFromBuildSettings(result.output), !bundleID.isEmpty {
                return bundleID
            }
        } catch {
            // Fall through to a readable placeholder that the user can edit.
        }

        let fallbackName = scheme
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: ".")
        return "com.example.\(fallbackName.isEmpty ? "app" : fallbackName)"
    }

    private static func defaultName(for url: URL) -> String {
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? url.deletingPathExtension().lastPathComponent : parent
    }

    private static func defaultDerivedDataPath(for url: URL, scheme: String) -> String {
        let safeName = "\(defaultName(for: url))-\(scheme)"
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return "~/Library/Developer/Xcode/DerivedData/LaunchPad-\(safeName)"
    }

    private static func parseBuildSettings(_ output: String) -> [String: String] {
        var settings: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let text = String(line)
            guard let range = text.range(of: " = ") else { continue }
            let key = String(text[..<range.lowerBound]).trimmed
            let value = String(text[range.upperBound...]).trimmed
            settings[key] = value
        }
        return settings
    }

    private static func extractJSON(from output: String) -> String {
        guard let start = output.firstIndex(of: "{"),
              let end = output.lastIndex(of: "}") else {
            return output
        }
        return String(output[start...end])
    }
}
