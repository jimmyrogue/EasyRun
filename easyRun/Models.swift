import Foundation
import SwiftUI

enum ProjectKind: String, Codable, CaseIterable {
    case project
    case workspace

    var xcodebuildFlag: String {
        switch self {
        case .project: return "-project"
        case .workspace: return "-workspace"
        }
    }
}

enum DeviceKind: String, Codable, CaseIterable {
    case simulator
    case physical
}

enum DevicePlatform {
    case iOS
    case tvOS
    case watchOS
    case visionOS
    case unknown

    var simulatorDestination: String {
        switch self {
        case .tvOS: return "tvOS Simulator"
        case .watchOS: return "watchOS Simulator"
        case .visionOS: return "visionOS Simulator"
        case .iOS, .unknown: return "iOS Simulator"
        }
    }

    var physicalDestination: String {
        switch self {
        case .tvOS: return "tvOS"
        case .watchOS: return "watchOS"
        case .visionOS: return "visionOS"
        case .iOS, .unknown: return "iOS"
        }
    }

    var simulatorBuildFolder: String {
        switch self {
        case .tvOS: return "appletvsimulator"
        case .watchOS: return "watchsimulator"
        case .visionOS: return "xrsimulator"
        case .iOS, .unknown: return "iphonesimulator"
        }
    }

    var physicalBuildFolder: String {
        switch self {
        case .tvOS: return "appletvos"
        case .watchOS: return "watchos"
        case .visionOS: return "xros"
        case .iOS, .unknown: return "iphoneos"
        }
    }

    static func infer(runtime: String, name: String) -> DevicePlatform {
        let value = "\(runtime) \(name)"
        if value.localizedCaseInsensitiveContains("tvOS") || value.localizedCaseInsensitiveContains("Apple TV") {
            return .tvOS
        }
        if value.localizedCaseInsensitiveContains("watchOS") || value.localizedCaseInsensitiveContains("Apple Watch") {
            return .watchOS
        }
        if value.localizedCaseInsensitiveContains("visionOS") || value.localizedCaseInsensitiveContains("Vision") {
            return .visionOS
        }
        if value.localizedCaseInsensitiveContains("iOS")
            || value.localizedCaseInsensitiveContains("iPhone")
            || value.localizedCaseInsensitiveContains("iPad") {
            return .iOS
        }
        return .unknown
    }
}

enum DeviceGroup: String, CaseIterable, Identifiable {
    case physical
    case iPhone
    case iPad
    case appleTV
    case appleWatch
    case vision
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .physical: return L10n.string("DeviceGroup.Physical")
        case .iPhone: return L10n.string("DeviceGroup.iPhone")
        case .iPad: return L10n.string("DeviceGroup.iPad")
        case .appleTV: return L10n.string("DeviceGroup.AppleTV")
        case .appleWatch: return L10n.string("DeviceGroup.AppleWatch")
        case .vision: return L10n.string("DeviceGroup.Vision")
        case .other: return L10n.string("DeviceGroup.Other")
        }
    }

    var symbolName: String {
        switch self {
        case .physical: return "cable.connector"
        case .iPhone: return "iphone.gen3"
        case .iPad: return "ipad.gen2"
        case .appleTV: return "appletv"
        case .appleWatch: return "applewatch"
        case .vision: return "vision.pro"
        case .other: return "display"
        }
    }

    var sortOrder: Int {
        switch self {
        case .physical: return 0
        case .iPhone: return 1
        case .iPad: return 2
        case .appleTV: return 3
        case .appleWatch: return 4
        case .vision: return 5
        case .other: return 6
        }
    }
}

enum ProjectStatus: String, Codable, CaseIterable {
    case idle
    case building
    case installing
    case launching
    case running
    case stopping
    case stopped
    case failed
    case cleaning

    var label: String {
        switch self {
        case .idle: return L10n.string("Status.Idle")
        case .building: return L10n.string("Status.Building")
        case .installing: return L10n.string("Status.Installing")
        case .launching: return L10n.string("Status.Launching")
        case .running: return L10n.string("Status.Running")
        case .stopping: return L10n.string("Status.Stopping")
        case .stopped: return L10n.string("Status.Stopped")
        case .failed: return L10n.string("Status.Failed")
        case .cleaning: return L10n.string("Status.Cleaning")
        }
    }

    var color: Color {
        switch self {
        case .idle, .stopped: return .secondary
        case .building, .installing, .launching, .stopping, .cleaning: return .yellow
        case .running: return .green
        case .failed: return .red
        }
    }

    var isBusy: Bool {
        switch self {
        case .building, .installing, .launching, .stopping, .cleaning:
            return true
        default:
            return false
        }
    }
}

struct RunDevice: Identifiable, Codable, Equatable {
    let udid: String
    var name: String
    var kind: DeviceKind
    var runtime: String
    var state: String
    var isAvailable: Bool
    var alternateIdentifiers: [String]? = nil

    var id: String { udid }

    func matches(_ identifier: String) -> Bool {
        identifier == udid || (alternateIdentifiers ?? []).contains(identifier)
    }

    var platform: DevicePlatform {
        DevicePlatform.infer(runtime: runtime, name: name)
    }

    var group: DeviceGroup {
        guard kind == .simulator else { return .physical }

        switch platform {
        case .tvOS:
            return .appleTV
        case .watchOS:
            return .appleWatch
        case .visionOS:
            return .vision
        case .iOS:
            return name.localizedCaseInsensitiveContains("iPad") ? .iPad : .iPhone
        case .unknown:
            return .other
        }
    }

    var symbolName: String {
        group.symbolName
    }

    var shortIdentifier: String {
        guard udid.count > 14 else { return udid }
        return "\(udid.prefix(8))...\(udid.suffix(4))"
    }

    var displayName: String {
        if kind == .physical {
            let details = [runtime, state, shortIdentifier].filter { !$0.trimmed.isEmpty }
            return details.isEmpty ? name : "\(name) · \(details.joined(separator: " · "))"
        }

        let suffix = runtime.isEmpty ? state : "\(runtime) · \(state)"
        return suffix.isEmpty ? name : "\(name) · \(suffix)"
    }
}

struct ManagedProject: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var path: String
    var kind: ProjectKind
    var scheme: String
    var schemes: [String]?
    var configuration = "Debug"
    var deviceID: String
    var deviceName: String
    var deviceKind: DeviceKind
    var deviceRuntime: String?
    var bundleID: String
    var derivedDataPath: String
    var createdAt = Date()
    var lastRunAt: Date?
    var lastRunDuration: TimeInterval?
    var status: ProjectStatus = .idle
    var statusMessage = L10n.string("StatusMessage.Ready")
    var buildLog = ""
    var runtimeLog = ""
    var logSearch = ""
    var isExpanded = false
    var lastDevicePID: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case path
        case kind
        case scheme
        case schemes
        case configuration
        case deviceID
        case deviceName
        case deviceKind
        case deviceRuntime
        case bundleID
        case derivedDataPath
        case createdAt
        case lastRunAt
        case lastRunDuration
    }

    var projectURL: URL {
        URL(fileURLWithPath: path)
    }

    var resolvedDerivedDataURL: URL {
        URL(fileURLWithPath: NSString(string: derivedDataPath).expandingTildeInPath)
    }

    var devicePlatform: DevicePlatform {
        DevicePlatform.infer(runtime: deviceRuntime ?? "", name: deviceName)
    }

    var displayDeviceName: String {
        deviceName.trimmed.isEmpty || deviceName == "No device"
            ? L10n.string("Device.NoDevice")
            : deviceName
    }

    var summaryLine: String {
        L10n.format("Project.SummaryLine", displayDeviceName, configuration, scheme)
    }

    var availableSchemes: [String] {
        var names = schemes ?? []
        if !scheme.trimmed.isEmpty, !names.contains(scheme) {
            names.insert(scheme, at: 0)
        }
        var seen = Set<String>()
        return names.compactMap { name in
            let trimmedName = name.trimmed
            guard !trimmedName.isEmpty, !seen.contains(trimmedName) else { return nil }
            seen.insert(trimmedName)
            return trimmedName
        }
    }
}

struct PersistedProjects: Codable {
    var projects: [ManagedProject]
}

struct XcodeListResponse: Decodable {
    struct Project: Decodable {
        var configurations: [String]?
        var name: String?
        var schemes: [String]?
        var targets: [String]?
    }

    struct Workspace: Decodable {
        var schemes: [String]?
    }

    var project: Project?
    var workspace: Workspace?
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
