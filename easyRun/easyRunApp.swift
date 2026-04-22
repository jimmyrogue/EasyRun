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
                Button("Add Project...") {
                    store.showAddPanel()
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
        }
    }
}
