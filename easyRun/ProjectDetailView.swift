import SwiftUI

struct ProjectDetailView: View {
    let project: ManagedProject
    @State private var selectedLog = LogKind.build
    @SceneStorage("configurationExpanded") private var configurationExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            ProjectHeaderControls(project: project)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                ProjectConfigurationView(project: project, isExpanded: $configurationExpanded)
                ProjectLogPanel(project: project, selectedLog: $selectedLog)
                    .layoutPriority(1)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            HStack(spacing: 8) {
                Text(L10n.string("Configuration.Title"))
                    .font(.headline)

                Text("\(project.scheme) · \(project.configuration)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
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

            EditableGridRow(title: L10n.string("Configuration.Scheme")) {
                TextField(L10n.string("Configuration.Scheme"), text: Binding(
                    get: { project.scheme },
                    set: { store.updateScheme(project.id, value: $0) }
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
