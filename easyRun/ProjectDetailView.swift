import SwiftUI

struct ProjectDetailView: View {
    let project: ManagedProject
    @State private var selectedLog = LogKind.build
    @State private var logsExpanded = false
    @SceneStorage("configurationExpanded") private var configurationExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            ProjectHeaderControls(project: project)

            VStack(alignment: .leading, spacing: 12) {
                ProjectConfigurationView(project: project, isExpanded: $configurationExpanded)
                ProjectLogPanel(project: project, selectedLog: $selectedLog, isExpanded: $logsExpanded)
                    .layoutPriority(1)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .navigationTitle(project.name)
    }
}

struct EmptyProjectView: View {
    @EnvironmentObject private var store: LaunchPadStore

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "xcode")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)

            Text(L10n.string("Empty.Title"))
                .font(.title3.weight(.semibold))

            Text(L10n.string("Empty.Message"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                store.showAddPanel()
            } label: {
                Label(L10n.string("Action.AddProject"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProjectConfigurationView: View {
    @EnvironmentObject private var store: LaunchPadStore
    let project: ManagedProject
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            configurationGrid
                .padding(.top, 10)
        } label: {
            HStack(spacing: 10) {
                ProjectSectionIcon(systemName: "slider.horizontal.3")

                Text(L10n.string("Configuration.Title"))
                    .font(.subheadline.weight(.semibold))

                Text("\(project.scheme) · \(project.configuration)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .detailSectionHeaderBackground(isActive: isExpanded)
        }
    }

    private var configurationGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            EditableGridRow(title: L10n.string("Configuration.Name")) {
                TextField(L10n.string("Configuration.Name"), text: Binding(
                    get: { project.name },
                    set: { store.updateName(project.id, value: $0) }
                ))
            }

            EditableGridRow(title: L10n.string("Configuration.Configuration")) {
                TextField(L10n.string("Configuration.Configuration"), text: Binding(
                    get: { project.configuration },
                    set: { store.updateConfiguration(project.id, value: $0) }
                ))
            }

            EditableGridRow(title: L10n.string("Configuration.BundleID")) {
                TextField(L10n.string("Configuration.BundleID"), text: Binding(
                    get: { project.bundleID },
                    set: { store.updateBundleID(project.id, value: $0) }
                ))
            }

            EditableGridRow(title: L10n.string("Configuration.DerivedData")) {
                TextField(L10n.string("Configuration.DerivedData"), text: Binding(
                    get: { project.derivedDataPath },
                    set: { store.updateDerivedDataPath(project.id, value: $0) }
                ))
            }
        }
        .textFieldStyle(.roundedBorder)
    }
}

struct ProjectSectionIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
    }
}

private struct DetailSectionHeaderBackground: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(isActive ? 0.85 : 0.55))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(nsColor: .separatorColor).opacity(isActive ? 0.38 : 0.22), lineWidth: 1)
            }
    }
}

extension View {
    func detailSectionHeaderBackground(isActive: Bool) -> some View {
        modifier(DetailSectionHeaderBackground(isActive: isActive))
    }
}

private struct EditableGridRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)

            content
                .frame(maxWidth: 520)
        }
    }
}
