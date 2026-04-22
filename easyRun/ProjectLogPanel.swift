import SwiftUI

struct ProjectLogPanel: View {
    @EnvironmentObject private var store: LaunchPadStore
    let project: ManagedProject
    @Binding var selectedLog: LogKind

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(L10n.string("Logs.Title"))
                    .font(.headline)

                Picker("", selection: $selectedLog) {
                    ForEach(LogKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 210)

                Spacer()

                if project.status == .failed {
                    Button {
                        store.openFirstError(for: project)
                    } label: {
                        Label(L10n.string("Action.OpenError"), systemImage: "arrow.up.forward.app")
                    }
                }

                Button {
                    store.copyLogs(for: project)
                } label: {
                    Label(L10n.string("Action.Copy"), systemImage: "doc.on.doc")
                }

                Button(role: .destructive) {
                    store.clearLogs(for: project)
                } label: {
                    Label(L10n.string("Action.Clear"), systemImage: "xmark.circle")
                }
            }

            LogSearchField(search: Binding(
                get: { project.logSearch },
                set: { store.updateLogSearch(project.id, value: $0) }
            ))

            LogTextView(
                text: selectedLog == .build ? project.buildLog : project.runtimeLog,
                search: project.logSearch
            )
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct LogSearchField: View {
    @Binding var search: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L10n.string("Logs.SearchPlaceholder"), text: $search)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: 360)
        .frame(height: 30)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct LogTextView: View {
    let text: String
    let search: String

    var body: some View {
        ScrollView {
            Text(filteredText.isEmpty ? L10n.string("Logs.Empty") : filteredText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(filteredText.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(minHeight: 360, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    private var filteredText: String {
        guard !search.trimmed.isEmpty else { return text }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.localizedCaseInsensitiveContains(search) }
            .joined(separator: "\n")
    }
}

enum LogKind: String, CaseIterable, Identifiable {
    case build
    case runtime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .build: return L10n.string("Logs.Build")
        case .runtime: return L10n.string("Logs.Runtime")
        }
    }
}
