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
