import SwiftUI

@main
struct easyRunApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = LaunchPadStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
        .defaultSize(width: 1020, height: 460)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.string("Action.AddProjectEllipsis")) {
                    store.showAddPanel()
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
        }
    }
}
