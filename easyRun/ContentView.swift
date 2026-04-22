import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: LaunchPadStore
    @SceneStorage("selectedProjectID") private var selectedProjectID = ""
    @State private var knownProjectIDs: [UUID] = []

    var body: some View {
        NavigationSplitView {
            ProjectSidebarView(selection: selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            if let project = selectedProject {
                ProjectDetailView(project: project)
            } else {
                EmptyProjectView()
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await store.refreshDevices() }
                } label: {
                    Label(L10n.string("Action.RefreshDevices"), systemImage: "arrow.clockwise")
                }
                .help(L10n.string("Help.RefreshDevices"))

                Button {
                    store.showAddPanel()
                } label: {
                    Label(L10n.string("Action.AddProject"), systemImage: "plus")
                }
                .help(L10n.string("Help.AddProject"))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $store.isDropTargeted, perform: handleDrop)
        .task {
            await store.bootstrap()
            reconcileSelection()
        }
        .onAppear {
            reconcileSelection()
        }
        .onChange(of: store.projects) { _ in
            reconcileSelection()
        }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { effectiveSelectedProjectID },
            set: { selectedProjectID = $0 ?? "" }
        )
    }

    private var effectiveSelectedProjectID: String? {
        if store.projects.contains(where: { $0.id.uuidString == selectedProjectID }) {
            return selectedProjectID
        }

        return store.projects.first?.id.uuidString
    }

    private var selectedProject: ManagedProject? {
        guard let effectiveSelectedProjectID else { return nil }
        return store.projects.first { $0.id.uuidString == effectiveSelectedProjectID }
    }

    private func reconcileSelection() {
        let projectIDs = store.projects.map(\.id)
        defer { knownProjectIDs = projectIDs }

        guard !projectIDs.isEmpty else {
            selectedProjectID = ""
            return
        }

        if let added = store.projects.first(where: { !knownProjectIDs.contains($0.id) }) {
            selectedProjectID = added.id.uuidString
            return
        }

        if store.projects.contains(where: { $0.id.uuidString == selectedProjectID }) {
            return
        }

        selectedProjectID = store.projects[0].id.uuidString
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

#Preview {
    ContentView()
        .environmentObject(LaunchPadStore.shared)
}
