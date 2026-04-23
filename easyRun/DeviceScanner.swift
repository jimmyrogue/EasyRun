import Foundation

enum DeviceScanner {
    static func scanDevices() async -> [RunDevice] {
        async let simulators = scanSimulators()
        async let physical = scanPhysicalDevices()
        return await (simulators + physical).sorted { lhs, rhs in
            if lhs.group != rhs.group { return lhs.group.sortOrder < rhs.group.sortOrder }
            if lhs.isAvailable != rhs.isAvailable { return lhs.isAvailable && !rhs.isAvailable }
            if lhs.kind != rhs.kind { return lhs.kind == .simulator }
            if lhs.state != rhs.state { return lhs.state == "Booted" }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func preferredDevice(from devices: [RunDevice]) -> RunDevice? {
        devices.first { $0.kind == .simulator && $0.state == "Booted" }
            ?? devices.first { $0.kind == .simulator && $0.name.localizedCaseInsensitiveContains("iPhone") && $0.isAvailable }
            ?? devices.first { $0.isAvailable }
            ?? devices.first
    }

    private static func scanSimulators() async -> [RunDevice] {
        do {
            let result = try await ShellCommand.run(
                "/usr/bin/xcrun",
                ["simctl", "list", "devices", "available", "--json"],
                checkExit: true
            )

            struct Response: Decodable {
                var devices: [String: [Device]]
            }

            struct Device: Decodable {
                var name: String
                var udid: String
                var state: String
                var isAvailable: Bool?
            }

            let response = try JSONDecoder().decode(Response.self, from: Data(result.output.utf8))
            return response.devices.flatMap { runtime, devices in
                devices.map {
                    RunDevice(
                        udid: $0.udid,
                        name: $0.name,
                        kind: .simulator,
                        runtime: readableRuntime(runtime),
                        state: $0.state,
                        isAvailable: $0.isAvailable ?? true
                    )
                }
            }
        } catch {
            return []
        }
    }

    private static func scanPhysicalDevices() async -> [RunDevice] {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("easyrun-devices-\(UUID().uuidString).json")

        defer { try? FileManager.default.removeItem(at: outputURL) }

        do {
            _ = try await ShellCommand.run(
                "/usr/bin/xcrun",
                ["devicectl", "list", "devices", "--json-output", outputURL.path],
                checkExit: false
            )

            let data = try Data(contentsOf: outputURL)

            struct Response: Decodable {
                struct Result: Decodable {
                    var devices: [Device]
                }

                struct Device: Decodable {
                    struct DeviceProperties: Decodable {
                        var name: String?
                        var osVersionNumber: String?
                    }

                    struct HardwareProperties: Decodable {
                        var marketingName: String?
                        var platform: String?
                        var udid: String?
                        var deviceType: String?
                    }

                    struct ConnectionProperties: Decodable {
                        var pairingState: String?
                        var tunnelState: String?
                    }

                    var identifier: String
                    var state: String?
                    var deviceProperties: DeviceProperties?
                    var hardwareProperties: HardwareProperties?
                    var connectionProperties: ConnectionProperties?
                }

                var result: Result
            }

            let response = try JSONDecoder().decode(Response.self, from: data)
            return response.result.devices.compactMap { device in
                guard device.hardwareProperties?.platform == "iOS" else { return nil }

                let hardwareUDID = device.hardwareProperties?.udid?.trimmed ?? ""
                let xcodeDeviceID = hardwareUDID.isEmpty ? device.identifier : hardwareUDID
                let alternateIdentifiers = [device.identifier, hardwareUDID]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .filter { $0 != xcodeDeviceID }
                let state = device.state ?? device.connectionProperties?.tunnelState ?? "unknown"
                let tunnelState = device.connectionProperties?.tunnelState ?? ""
                let isPaired = device.connectionProperties?.pairingState == "paired"
                let isAvailable = state.caseInsensitiveCompare("available") == .orderedSame
                    || tunnelState.caseInsensitiveCompare("connected") == .orderedSame
                    || (isPaired && !xcodeDeviceID.trimmed.isEmpty)

                return RunDevice(
                    udid: xcodeDeviceID,
                    name: device.deviceProperties?.name
                        ?? device.hardwareProperties?.marketingName
                        ?? xcodeDeviceID,
                    kind: .physical,
                    runtime: device.deviceProperties?.osVersionNumber.map { "iOS \($0)" } ?? "iOS",
                    state: state,
                    isAvailable: isAvailable,
                    alternateIdentifiers: alternateIdentifiers
                )
            }
        } catch {
            return []
        }
    }

    private static func readableRuntime(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "iOS ", with: "iOS ")
    }
}
