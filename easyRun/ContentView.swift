import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: LaunchPadStore

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()

            Group {
                if store.projects.isEmpty {
                    EmptyProjectDropZone()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(store.projects) { project in
                                ProjectCard(project: project)
                            }
                        }
                        .padding(20)
                    }
                    .background(Color(nsColor: .windowBackgroundColor))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            FooterView()
        }
        .frame(minWidth: 820, minHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: $store.isDropTargeted, perform: handleDrop)
        .task {
            await store.bootstrap()
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data,
                   let string = String(data: data, encoding: .utf8),
                   let fileURL = URL(string: string) {
                    url = fileURL
                } else if let fileURL = item as? URL {
                    url = fileURL
                } else {
                    url = nil
                }

                DispatchQueue.main.async {
                    if let url {
                        urls.append(url)
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            store.addProjects(from: urls)
        }

        return true
    }
}

private struct HeaderView: View {
    @EnvironmentObject private var store: LaunchPadStore

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("LaunchPad for iOS")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(store.xcodePath.isEmpty ? "Xcode tools not detected" : store.xcodePath)
                    .font(.caption)
                    .foregroundStyle(store.xcodePath.isEmpty ? .red : .secondary)
                    .lineLimit(1)
            }

            Spacer()

            IconButton(systemName: "arrow.clockwise", help: "Refresh devices") {
                Task { await store.refreshDevices() }
            }

            IconButton(systemName: "plus", help: "Add project") {
                store.showAddPanel()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
    }
}

private struct FooterView: View {
    @EnvironmentObject private var store: LaunchPadStore

    var body: some View {
        HStack(spacing: 14) {
            FooterMetric(systemName: "square.stack.3d.up", value: "\(store.projects.count)")
            FooterMetric(systemName: "iphone.gen3", value: "\(store.devices.filter(\.isAvailable).count)")

            if let message = store.globalMessage {
                FooterDivider()
                Text(message)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
            }

            Spacer(minLength: 12)

            if store.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.72)
            }

            Text(store.isBusy ? "Working" : "Ready")
                .font(.caption.weight(.medium))
                .foregroundStyle(store.hasFailure ? .red : .secondary)
                .frame(minWidth: 48, alignment: .trailing)
        }
        .font(.caption)
        .padding(.horizontal, 20)
        .frame(height: 44)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct FooterMetric: View {
    let systemName: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemName)
                .frame(width: 13)
            Text(value)
                .font(.caption.monospacedDigit())
                .frame(minWidth: 16, alignment: .leading)
        }
        .foregroundStyle(.secondary)
    }
}

private struct FooterDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.22))
            .frame(width: 1, height: 14)
    }
}

private struct EmptyProjectDropZone: View {
    @EnvironmentObject private var store: LaunchPadStore

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(store.isDropTargeted ? 0.22 : 0.12))
                    .frame(width: 86, height: 86)
                Image(systemName: "xcode")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 6) {
                Text("Drop a folder that contains an Xcode project")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("The app scans for .xcodeproj and .xcworkspace packages automatically.")
                    .foregroundStyle(.secondary)
            }

            Button {
                store.showAddPanel()
            } label: {
                Label("Add Project", systemImage: "plus")
                    .frame(minWidth: 128)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(30)
    }
}

private struct ProjectCard: View {
    @EnvironmentObject private var store: LaunchPadStore
    let project: ManagedProject

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Circle()
                    .fill(project.status.color)
                    .frame(width: 12, height: 12)
                    .shadow(color: project.status.color.opacity(0.45), radius: 6)
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(project.name)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                        Text(project.status.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(project.status.color)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(project.status.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    }

                    Text(project.summaryLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(lastRunText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    ProjectStatusLine(project: project)
                }

                Spacer(minLength: 12)

                DevicePicker(project: project)
                    .frame(width: 210)

                HStack(spacing: 8) {
                    ProjectActionButton(project: project)

                    MoreActionsMenu(project: project)

                    IconButton(systemName: project.isExpanded ? "chevron.up" : "chevron.down", help: "Toggle details") {
                        store.toggleExpanded(project)
                    }
                }
            }
            .padding(16)

            if project.isExpanded {
                Divider()
                ProjectDetails(project: project)
                    .padding(16)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.08))
        )
    }

    private var lastRunText: String {
        guard let lastRunAt = project.lastRunAt else { return "Never run" }
        let date = lastRunAt.formatted(date: .omitted, time: .shortened)
        if let duration = project.lastRunDuration {
            return "Last run: \(date) (\(String(format: "%.1f", duration))s)"
        }
        return "Last run: \(date)"
    }
}

private struct ProjectStatusLine: View {
    let project: ManagedProject

    var body: some View {
        HStack(spacing: 6) {
            if project.status.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.65)
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: statusIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(project.status.color)
                    .frame(width: 12, height: 12)
            }

            Text(project.statusMessage)
                .lineLimit(1)
                .foregroundStyle(project.status == .failed ? .red : .secondary)
        }
        .font(.caption)
        .frame(height: 16, alignment: .leading)
    }

    private var statusIcon: String {
        switch project.status {
        case .running:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .stopped:
            return "stop.circle.fill"
        default:
            return "checkmark.circle"
        }
    }
}

private struct ProjectActionButton: View {
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
            HStack(spacing: 7) {
                if project.status.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.72)
                        .frame(width: 13, height: 13)
                } else {
                    Image(systemName: iconName)
                }

                Text(title)
                    .lineLimit(1)
            }
            .frame(width: 92)
        }
        .buttonStyle(ActionButtonStyle(tone: tone))
        .disabled(isDisabled)
        .help(help)
    }

    private var title: String {
        if project.status.isBusy { return project.status.label }
        return project.status == .running ? "Stop" : "Run"
    }

    private var iconName: String {
        project.status == .running ? "stop.fill" : "play.fill"
    }

    private var tone: ActionButtonStyle.Tone {
        if project.status == .running { return .stop }
        if project.status.isBusy { return .busy }
        return .run
    }

    private var isDisabled: Bool {
        project.status.isBusy || (project.status != .running && store.devices.isEmpty)
    }

    private var help: String {
        if project.status.isBusy { return project.statusMessage }
        return project.status == .running ? "Stop app" : "Build and run"
    }
}

private struct MoreActionsMenu: View {
    @EnvironmentObject private var store: LaunchPadStore
    let project: ManagedProject

    var body: some View {
        Menu {
            Button {
                Task { await store.clean(project) }
            } label: {
                Label("Clean DerivedData", systemImage: "eraser")
            }
            .disabled(project.status.isBusy)

            Divider()

            Button(role: .destructive) {
                store.remove(project)
            } label: {
                Label("Remove from List", systemImage: "minus.circle")
            }
            .disabled(project.status.isBusy)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Color(nsColor: .controlColor), in: RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("More actions")
    }
}

private struct DevicePicker: View {
    @EnvironmentObject private var store: LaunchPadStore
    let project: ManagedProject

    var body: some View {
        Picker("", selection: Binding(
            get: { project.deviceID },
            set: { store.selectDevice(projectID: project.id, deviceID: $0) }
        )) {
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
        .help("Target device")
        .disabled(store.devices.isEmpty || project.status.isBusy)
    }
}

private struct ProjectDetails: View {
    @EnvironmentObject private var store: LaunchPadStore
    let project: ManagedProject
    @State private var selectedLog = LogKind.build

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                EditableField(title: "Name", value: Binding(
                    get: { project.name },
                    set: { store.updateName(project.id, value: $0) }
                ))

                EditableField(title: "Scheme", value: Binding(
                    get: { project.scheme },
                    set: { store.updateScheme(project.id, value: $0) }
                ))

                EditableField(title: "Configuration", value: Binding(
                    get: { project.configuration },
                    set: { store.updateConfiguration(project.id, value: $0) }
                ))
            }

            HStack(spacing: 12) {
                EditableField(title: "Bundle ID", value: Binding(
                    get: { project.bundleID },
                    set: { store.updateBundleID(project.id, value: $0) }
                ))

                EditableField(title: "DerivedData", value: Binding(
                    get: { project.derivedDataPath },
                    set: { store.updateDerivedDataPath(project.id, value: $0) }
                ))
            }

            HStack(spacing: 8) {
                Picker("", selection: $selectedLog) {
                    ForEach(LogKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                Spacer()

                if project.status == .failed {
                    Button {
                        store.openFirstError(for: project)
                    } label: {
                        Label("Open Error", systemImage: "arrow.up.forward.app")
                    }
                }

                Button {
                    store.copyLogs(for: project)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }

                Button(role: .destructive) {
                    store.clearLogs(for: project)
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
            }

            LogViewer(text: selectedLog == .build ? project.buildLog : project.runtimeLog, search: Binding(
                get: { project.logSearch },
                set: { value in
                    if let index = store.projects.firstIndex(where: { $0.id == project.id }) {
                        store.projects[index].logSearch = value
                    }
                }
            ))
        }
    }
}

private struct EditableField: View {
    let title: String
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField(title, text: $value)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct LogViewer: View {
    let text: String
    @Binding var search: String

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search log", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))

            ScrollView {
                Text(filteredText.isEmpty ? "No log output yet." : filteredText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .foregroundStyle(filteredText.isEmpty ? .secondary : .primary)
                    .padding(12)
            }
            .frame(minHeight: 190, maxHeight: 260)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private var filteredText: String {
        guard !search.trimmed.isEmpty else { return text }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.localizedCaseInsensitiveContains(search) }
            .joined(separator: "\n")
    }
}

private struct IconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(IconButtonStyle())
        .help(help)
    }
}

private struct ActionButtonStyle: ButtonStyle {
    enum Tone {
        case run
        case stop
        case busy
    }

    @Environment(\.isEnabled) private var isEnabled
    let tone: Tone

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .frame(height: 30)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor(configuration: configuration), in: RoundedRectangle(cornerRadius: 7))
            .opacity(isEnabled || tone == .busy ? 1 : 0.55)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        switch tone {
        case .busy:
            return .secondary
        case .run, .stop:
            return .white
        }
    }

    private func backgroundColor(configuration: Configuration) -> Color {
        switch tone {
        case .run:
            return Color.accentColor.opacity(configuration.isPressed ? 0.82 : 1)
        case .stop:
            return Color.red.opacity(configuration.isPressed ? 0.78 : 0.92)
        case .busy:
            return Color(nsColor: .controlColor)
        }
    }
}

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .background(Color(nsColor: .controlColor).opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: 7))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .foregroundStyle(.white)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.82 : 1), in: RoundedRectangle(cornerRadius: 7))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private enum LogKind: String, CaseIterable, Identifiable {
    case build
    case runtime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .build: return "Build Log"
        case .runtime: return "Runtime Log"
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(LaunchPadStore.shared)
}
