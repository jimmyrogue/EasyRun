import SwiftUI

struct ProjectSidebarView: View {
    @EnvironmentObject private var store: LaunchPadStore
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            Section(L10n.string("Sidebar.Projects")) {
                ForEach(store.projects) { project in
                    ProjectSidebarRow(project: project)
                        .tag(project.id.uuidString)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if store.projects.isEmpty {
                Text(L10n.string("Sidebar.NoProjects"))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProjectSidebarRow: View {
    let project: ManagedProject

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(project.status.color)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(project.displayDeviceName)
                        .lineLimit(1)
                    Text("·")
                    Text(project.status.label)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusSymbol: String {
        switch project.status {
        case .running:
            return "play.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .building, .installing, .launching, .stopping, .cleaning:
            return "bolt.circle.fill"
        case .stopped:
            return "stop.circle"
        case .idle:
            return "circle"
        }
    }
}
