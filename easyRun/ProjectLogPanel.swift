import SwiftUI
import AppKit

struct ProjectLogPanel: View {
    @EnvironmentObject private var store: LaunchPadStore
    let project: ManagedProject
    @Binding var selectedLog: LogKind
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if isExpanded {
                logContent
                    .padding(.top, 10)
            }
        } label: {
            HStack(spacing: 10) {
                ProjectSectionIcon(systemName: "terminal")

                Text(L10n.string("Logs.Title"))
                    .font(.subheadline.weight(.semibold))

                Text(selectedLog.label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .detailSectionHeaderBackground(isActive: isExpanded)
        }
        .frame(maxWidth: .infinity, maxHeight: isExpanded ? .infinity : nil, alignment: .topLeading)
    }

    private var logContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Picker("", selection: $selectedLog) {
                    ForEach(LogKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
                .controlSize(.small)

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
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color(nsColor: .separatorColor).opacity(0.34), lineWidth: 1)
        }
    }
}

private struct LogTextView: View {
    let text: String
    let search: String

    var body: some View {
        let renderedText = limited(filteredText)

        ZStack(alignment: .topLeading) {
            LogTextStorageView(text: renderedText)
                .opacity(renderedText.isEmpty ? 0 : 1)

            if renderedText.isEmpty {
                Text(L10n.string("Logs.Empty"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
        .frame(minHeight: 360, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color(nsColor: .separatorColor).opacity(0.42), lineWidth: 1)
        }
    }

    private var filteredText: String {
        let query = search.trimmed
        guard !query.isEmpty else { return text }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.localizedCaseInsensitiveContains(query) }
            .joined(separator: "\n")
    }

    private func limited(_ value: String) -> String {
        let limit = 60_000
        guard value.count > limit else { return value }
        return String(value.suffix(limit))
    }
}

private struct LogTextStorageView: NSViewRepresentable {
    let text: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textColor = .labelColor

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              context.coordinator.lastText != text else {
            return
        }

        textView.string = text
        context.coordinator.lastText = text
        scrollToBottom(textView)
    }

    private func scrollToBottom(_ textView: NSTextView) {
        guard !textView.string.isEmpty else { return }
        if let textContainer = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: textContainer)
        }

        let range = NSRange(location: textView.string.utf16.count, length: 0)
        textView.scrollRangeToVisible(range)
        DispatchQueue.main.async {
            let range = NSRange(location: textView.string.utf16.count, length: 0)
            textView.scrollRangeToVisible(range)
        }
    }

    final class Coordinator {
        var lastText = ""
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
