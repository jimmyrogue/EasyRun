import SwiftUI

struct ProjectHeaderControls: View {
    @EnvironmentObject private var store: LaunchPadStore
    let project: ManagedProject

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                ProjectStatusSummary(project: project)
                    .frame(width: 116, alignment: .leading)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    ProjectSchemePicker(project: project)
                        .frame(width: 170)

                    DevicePicker(project: project)
                        .frame(width: 210)

                    Divider()
                        .frame(height: 18)
                        .padding(.horizontal, 2)

                    ProjectRunButton(project: project)

                    ProjectMoreMenu(project: project)
                }
                .layoutPriority(2)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)

            Divider()
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ProjectSchemePicker: View {
    @EnvironmentObject private var store: LaunchPadStore
    let project: ManagedProject

    var body: some View {
        Picker(L10n.string("Configuration.Scheme"), selection: Binding(
            get: { project.scheme },
            set: { store.updateScheme(project.id, value: $0) }
        )) {
            if !project.availableSchemes.contains(project.scheme) {
                Text(project.scheme).tag(project.scheme)
            }

            ForEach(project.availableSchemes, id: \.self) { scheme in
                Text(scheme).tag(scheme)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .help(L10n.string("Configuration.Scheme"))
        .disabled(project.availableSchemes.isEmpty || project.status.isBusy)
        .task(id: project.id) {
            await store.refreshSchemesIfNeeded(for: project.id)
        }
    }
}

struct ProjectStatusSummary: View {
    let project: ManagedProject

    var body: some View {
        HStack(spacing: 6) {
            if project.status.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.72)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: statusSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(statusColor)
                    .frame(width: 16, height: 16)
            }

            Text(project.statusMessage)
                .lineLimit(1)
                .foregroundStyle(project.status == .failed ? .red : .secondary)
        }
        .font(.subheadline)
    }

    private var statusSymbol: String {
        switch project.status {
        case .running:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .stopped:
            return "stop.circle.fill"
        case .building, .installing, .launching, .stopping, .cleaning:
            return "bolt.circle.fill"
        case .idle:
            return "circle"
        }
    }

    private var statusColor: Color {
        switch project.status {
        case .running:
            return .accentColor
        case .failed:
            return .red
        case .building, .installing, .launching, .stopping, .cleaning:
            return .orange
        case .stopped, .idle:
            return .secondary
        }
    }
}

struct DevicePicker: View {
    @EnvironmentObject private var store: LaunchPadStore
    let project: ManagedProject

    var body: some View {
        Picker(L10n.string("Control.TargetDevice"), selection: Binding(
            get: { selectedDeviceID },
            set: { store.selectDevice(projectID: project.id, deviceID: $0) }
        )) {
            if !hasSelectedDevice {
                Label(selectedDeviceTitle, systemImage: selectedDeviceSymbol)
                    .tag(project.deviceID)
            }

            ForEach(DeviceGroup.allCases) { group in
                let devices = store.devices.filter { $0.group == group }
                if !devices.isEmpty {
                    Section(group.title) {
                        ForEach(devices) { device in
                            Label(device.displayName, systemImage: device.symbolName)
                                .tag(device.id)
                                .disabled(!device.isAvailable)
                        }
                    }
                }
            }
        }
        .labelsHidden()
        .help(L10n.string("Help.TargetDevice"))
        .disabled(store.devices.isEmpty || project.status.isBusy)
    }

    private var selectedDeviceID: String {
        store.devices.first { $0.matches(project.deviceID) }?.id ?? project.deviceID
    }

    private var hasSelectedDevice: Bool {
        store.devices.contains { $0.id == selectedDeviceID }
    }

    private var selectedDeviceTitle: String {
        project.displayDeviceName
    }

    private var selectedDeviceSymbol: String {
        if project.deviceKind == .physical {
            return DeviceGroup.physical.symbolName
        }

        switch project.devicePlatform {
        case .tvOS:
            return DeviceGroup.appleTV.symbolName
        case .watchOS:
            return DeviceGroup.appleWatch.symbolName
        case .visionOS:
            return DeviceGroup.vision.symbolName
        case .iOS:
            return project.deviceName.localizedCaseInsensitiveContains("iPad")
                ? DeviceGroup.iPad.symbolName
                : DeviceGroup.iPhone.symbolName
        case .unknown:
            return DeviceGroup.other.symbolName
        }
    }
}

struct ProjectRunButton: View {
    @EnvironmentObject private var store: LaunchPadStore
    let project: ManagedProject

    var body: some View {
        Button {
            Task {
                if project.status == .running {
                    await store.stop(project)
                } else {
                    await store.run(project)
                }
            }
        } label: {
            Label(title, systemImage: iconName)
                .frame(minWidth: 68)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle)
        .controlSize(.regular)
        .tint(tint)
        .disabled(isDisabled)
        .help(help)
    }

    private var title: String {
        if project.status.isBusy { return project.status.label }
        return project.status == .running ? L10n.string("Action.Stop") : L10n.string("Action.Run")
    }

    private var iconName: String {
        project.status == .running ? "stop.fill" : "play.fill"
    }

    private var tint: Color {
        project.status == .running ? .red : .accentColor
    }

    private var isDisabled: Bool {
        project.status.isBusy || (project.status != .running && store.devices.isEmpty)
    }

    private var help: String {
        if project.status.isBusy { return project.statusMessage }
        return project.status == .running ? L10n.string("Help.StopApp") : L10n.string("Help.BuildAndRun")
    }
}

struct ProjectMoreMenu: View {
    @EnvironmentObject private var store: LaunchPadStore
    let project: ManagedProject

    var body: some View {
        Menu {
            Button {
                Task { await store.clean(project) }
            } label: {
                Label(L10n.string("Action.CleanDerivedData"), systemImage: "eraser")
            }
            .disabled(project.status.isBusy)

            Divider()

            Button(role: .destructive) {
                store.remove(project)
            } label: {
                Label(L10n.string("Action.RemoveFromList"), systemImage: "minus.circle")
            }
            .disabled(project.status.isBusy)
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(L10n.string("Help.MoreActions"))
    }
}
