import Foundation

struct BuildProductInfo: Sendable {
    var bundleID: String
    var appURL: URL
    var executableName: String
    var buildFolder: String
    var resolvedAt: Date
}

struct RunPhaseTiming {
    var name: String
    var startedAt: Date
    var endedAt: Date

    var duration: TimeInterval {
        endedAt.timeIntervalSince(startedAt)
    }
}

enum BuildProductResolver {
    static func resolve(project: ManagedProject, cached: BuildProductInfo?) async throws -> BuildProductInfo {
        let input = BuildProductLookupInput(project: project)
        return try await Task.detached(priority: .userInitiated) {
            try resolve(input: input, cached: cached)
        }.value
    }

    static func info(for appURL: URL, buildFolder: String, fallbackBundleID: String) throws -> BuildProductInfo {
        let plist = appURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let values = object as? [String: Any] else {
            throw BuildProductResolverError.missingInfoPlist(appURL.path)
        }

        let plistBundleID = (values["CFBundleIdentifier"] as? String)?.trimmed ?? ""
        let bundleID = plistBundleID.isEmpty ? fallbackBundleID.trimmed : plistBundleID
        guard !bundleID.isEmpty else {
            throw BuildProductResolverError.missingBundleIdentifier(appURL.path)
        }

        let plistExecutableName = (values["CFBundleExecutable"] as? String)?.trimmed ?? ""
        let executableName = plistExecutableName.isEmpty
            ? appURL.deletingPathExtension().lastPathComponent
            : plistExecutableName

        return BuildProductInfo(
            bundleID: bundleID,
            appURL: appURL,
            executableName: executableName,
            buildFolder: buildFolder,
            resolvedAt: Date()
        )
    }

    private static func resolve(input: BuildProductLookupInput, cached: BuildProductInfo?) throws -> BuildProductInfo {
        if let cached, FileManager.default.fileExists(atPath: cached.appURL.path) {
            return try info(for: cached.appURL, buildFolder: input.buildFolder, fallbackBundleID: cached.bundleID)
        }

        let productsURL = input.derivedDataURL
            .appendingPathComponent("Build/Products")
            .appendingPathComponent("\(input.configuration)-\(input.buildFolder)")

        let appURLs = try appBundles(in: productsURL)
        let selected = try selectBestApp(from: appURLs, input: input)
        return try info(for: selected, buildFolder: input.buildFolder, fallbackBundleID: input.bundleID)
    }

    private static func appBundles(in productsURL: URL) throws -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: productsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw BuildProductResolverError.productDirectoryMissing(productsURL.path)
        }

        let appURLs = urls.filter { $0.pathExtension == "app" }
        guard !appURLs.isEmpty else {
            throw BuildProductResolverError.productNotFound(productsURL.path)
        }
        return appURLs
    }

    private static func selectBestApp(from appURLs: [URL], input: BuildProductLookupInput) throws -> URL {
        let expectedBundleID = input.bundleID.trimmed
        if !expectedBundleID.isEmpty,
           let match = appURLs.first(where: { appURL in
               (try? info(for: appURL, buildFolder: input.buildFolder, fallbackBundleID: "").bundleID) == expectedBundleID
           }) {
            return match
        }

        let expectedName = "\(input.scheme).app"
        if let match = appURLs.first(where: { $0.lastPathComponent == expectedName }) {
            return match
        }

        if let match = appURLs.first(where: {
            $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(input.scheme)
        }) {
            return match
        }

        return appURLs
            .sorted { lhs, rhs in
                modificationDate(for: lhs) > modificationDate(for: rhs)
            }
            .first!
    }

    private static func modificationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

private struct BuildProductLookupInput: Sendable {
    var scheme: String
    var configuration: String
    var bundleID: String
    var derivedDataURL: URL
    var buildFolder: String

    init(project: ManagedProject) {
        scheme = project.scheme
        configuration = project.configuration
        bundleID = project.bundleID
        derivedDataURL = project.resolvedDerivedDataURL
        buildFolder = project.deviceKind == .simulator
            ? project.devicePlatform.simulatorBuildFolder
            : project.devicePlatform.physicalBuildFolder
    }
}

private enum BuildProductResolverError: LocalizedError {
    case productDirectoryMissing(String)
    case productNotFound(String)
    case missingInfoPlist(String)
    case missingBundleIdentifier(String)

    var errorDescription: String? {
        switch self {
        case .productDirectoryMissing(let path):
            return L10n.format("Error.ProductDirectoryMissingFormat", path)
        case .productNotFound(let path):
            return L10n.format("Error.ProductNotFoundFormat", path)
        case .missingInfoPlist(let path):
            return L10n.format("Error.InfoPlistMissingFormat", path)
        case .missingBundleIdentifier(let path):
            return L10n.format("Error.BundleIDMissingFormat", path)
        }
    }
}
