import AppKit
import Combine
import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let statusController = StatusBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        statusController.configure(store: LaunchPadStore.shared)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            MainWindowPresenter.show()
        }
    }
}

@MainActor
private final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private weak var store: LaunchPadStore?
    private var cancellables = Set<AnyCancellable>()
    private var actions: [MenuAction] = []

    func configure(store: LaunchPadStore) {
        self.store = store
        statusItem.button?.image = NSImage(systemSymbolName: "play.square.stack", accessibilityDescription: "LaunchPad for iOS")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = " Run"
        rebuildMenu()

        store.$projects
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)

        store.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
    }

    private func rebuildMenu() {
        guard let store else { return }

        let menu = NSMenu()
        actions.removeAll()
        updateStatusItem()

        if store.projects.isEmpty {
            let empty = NSMenuItem(title: "No Projects Yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (index, project) in store.projects.prefix(9).enumerated() {
                addProjectMenu(for: project, index: index, to: menu)
            }
        }

        menu.addItem(.separator())

        addMenuItem("Add Project...", image: "plus", action: { [weak store] in
            store?.showAddPanel()
        }, to: menu)

        addMenuItem("Refresh Devices", image: "arrow.clockwise", action: { [weak store] in
            Task { await store?.refreshDevices() }
        }, to: menu)

        addMenuItem("Show Main Window", image: "macwindow", action: {
            MainWindowPresenter.show()
        }, to: menu)

        menu.addItem(.separator())
        addMenuItem("Quit", image: "power", action: {
            NSApp.terminate(nil)
        }, to: menu)

        statusItem.menu = menu
    }

    private func addProjectMenu(for project: ManagedProject, index: Int, to menu: NSMenu) {
        guard let store else { return }

        let item = NSMenuItem(title: project.name, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: menuIcon(for: project.status), accessibilityDescription: nil)
        item.toolTip = project.summaryLine

        let submenu = NSMenu()
        let statusItem = NSMenuItem(title: "\(project.status.label): \(project.statusMessage)", action: nil, keyEquivalent: "")
        statusItem.image = NSImage(systemSymbolName: menuIcon(for: project.status), accessibilityDescription: nil)
        statusItem.isEnabled = false
        submenu.addItem(statusItem)

        let actionTitle = primaryActionTitle(for: project)
        let actionImage = project.status == .running ? "stop.fill" : "play.fill"
        let action = MenuAction { [weak store] in
            guard let store,
                  let currentProject = store.projects.first(where: { $0.id == project.id }) else { return }

            Task {
                if currentProject.status == .running {
                    await store.stop(currentProject)
                } else {
                    await store.run(currentProject)
                }
            }
        }
        actions.append(action)

        let actionItem = NSMenuItem(
            title: actionTitle,
            action: #selector(MenuAction.runAction),
            keyEquivalent: "\(index + 1)"
        )
        actionItem.target = action
        actionItem.image = NSImage(systemSymbolName: actionImage, accessibilityDescription: nil)
        actionItem.isEnabled = canUsePrimaryAction(project, store: store)
        submenu.addItem(actionItem)

        let targetItem = NSMenuItem(title: "Target Device", action: nil, keyEquivalent: "")
        targetItem.image = NSImage(systemSymbolName: "iphone.gen3", accessibilityDescription: nil)
        targetItem.submenu = deviceMenu(for: project, store: store)
        targetItem.isEnabled = !project.status.isBusy && !store.devices.isEmpty
        submenu.addItem(targetItem)

        item.submenu = submenu
        menu.addItem(item)
    }

    private func deviceMenu(for project: ManagedProject, store: LaunchPadStore) -> NSMenu {
        let menu = NSMenu()

        if store.devices.isEmpty {
            let item = NSMenuItem(title: "No Devices Found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return menu
        }

        for group in DeviceGroup.allCases {
            let devices = store.devices.filter { $0.group == group }
            guard !devices.isEmpty else { continue }

            let groupItem = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            groupItem.image = NSImage(systemSymbolName: group.symbolName, accessibilityDescription: nil)
            groupItem.state = devices.contains { $0.id == project.deviceID } ? .on : .off
            groupItem.isEnabled = !project.status.isBusy
            groupItem.submenu = deviceGroupMenu(for: devices, project: project, store: store)
            menu.addItem(groupItem)
        }

        return menu
    }

    private func deviceGroupMenu(for devices: [RunDevice], project: ManagedProject, store: LaunchPadStore) -> NSMenu {
        let menu = NSMenu()

        for device in devices {
            let token = MenuAction { [weak store] in
                store?.selectDevice(projectID: project.id, deviceID: device.id)
            }
            actions.append(token)

            let item = NSMenuItem(
                title: device.displayName,
                action: #selector(MenuAction.runAction),
                keyEquivalent: ""
            )
            item.target = token
            item.image = NSImage(systemSymbolName: device.symbolName, accessibilityDescription: nil)
            item.state = device.id == project.deviceID ? .on : .off
            item.isEnabled = device.isAvailable && !project.status.isBusy
            menu.addItem(item)
        }

        return menu
    }

    private func addMenuItem(_ title: String, image: String, action: @escaping () -> Void, to menu: NSMenu) {
        let token = MenuAction(action)
        actions.append(token)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.runAction), keyEquivalent: "")
        item.target = token
        item.image = NSImage(systemSymbolName: image, accessibilityDescription: nil)
        menu.addItem(item)
    }

    private func updateStatusItem() {
        guard let button = statusItem.button, let store else { return }

        if store.hasFailure {
            button.image = NSImage(systemSymbolName: "xmark.octagon.fill", accessibilityDescription: "LaunchPad failed")
            button.title = " Issue"
            button.contentTintColor = .systemRed
        } else if store.isBusy {
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "LaunchPad running")
            button.title = " Working"
            button.contentTintColor = .systemYellow
        } else if store.projects.contains(where: { $0.status == .running }) {
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "LaunchPad app running")
            button.title = " Running"
            button.contentTintColor = .systemGreen
        } else {
            button.image = NSImage(systemSymbolName: "play.square.stack", accessibilityDescription: "LaunchPad for iOS")
            button.title = " Run"
            button.contentTintColor = nil
        }
    }

    private func primaryActionTitle(for project: ManagedProject) -> String {
        if project.status.isBusy { return "\(project.status.label)..." }
        return project.status == .running ? "Stop \(project.name)" : "Run \(project.name)"
    }

    private func canUsePrimaryAction(_ project: ManagedProject, store: LaunchPadStore) -> Bool {
        if project.status.isBusy { return false }
        if project.status == .running { return true }
        return !store.devices.isEmpty && !project.deviceID.trimmed.isEmpty
    }

    private func menuIcon(for status: ProjectStatus) -> String {
        switch status {
        case .idle:
            return "circle"
        case .building, .installing, .launching, .stopping, .cleaning:
            return "bolt.fill"
        case .running:
            return "checkmark.circle.fill"
        case .stopped:
            return "stop.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }
}

@MainActor
private final class MenuAction: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func runAction() {
        action()
    }
}

@MainActor
private enum MainWindowPresenter {
    private static weak var manualWindow: NSWindow?

    static func show() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) {
            window.makeKeyAndOrderFront(nil)
            return
        }

        if let manualWindow {
            manualWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LaunchPad for iOS"
        window.center()
        window.contentView = NSHostingView(
            rootView: ContentView()
                .environmentObject(LaunchPadStore.shared)
        )
        window.makeKeyAndOrderFront(nil)
        manualWindow = window
    }
}
