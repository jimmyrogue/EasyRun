import AppKit
import Combine
import Foundation
import SwiftUI
import UserNotifications

private struct MenuProjectSnapshot: Equatable {
    var id: UUID
    var name: String
    var scheme: String
    var configuration: String
    var deviceID: String
    var deviceName: String
    var status: ProjectStatus
    var statusMessage: String

    init(project: ManagedProject) {
        id = project.id
        name = project.name
        scheme = project.scheme
        configuration = project.configuration
        deviceID = project.deviceID
        deviceName = project.deviceName
        status = project.status
        statusMessage = project.statusMessage
    }
}

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
        statusItem.button?.image = NSImage(
            systemSymbolName: "play.square.stack",
            accessibilityDescription: L10n.string("Accessibility.LaunchPadForIOS")
        )
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = " " + L10n.string("Action.Run")
        rebuildMenu()

        store.$projects
            .map { $0.map(MenuProjectSnapshot.init(project:)) }
            .removeDuplicates()
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
            let empty = NSMenuItem(title: L10n.string("Menu.NoProjectsYet"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (index, project) in store.projects.prefix(9).enumerated() {
                addProjectMenu(for: project, index: index, to: menu)
            }
        }

        menu.addItem(.separator())

        addMenuItem(L10n.string("Action.AddProjectEllipsis"), image: "plus", action: { [weak store] in
            store?.showAddPanel()
        }, to: menu)

        addMenuItem(L10n.string("Action.RefreshDevices"), image: "arrow.clockwise", action: { [weak store] in
            Task { await store?.refreshDevices() }
        }, to: menu)

        addMenuItem(L10n.string("Action.ShowMainWindow"), image: "macwindow", action: {
            MainWindowPresenter.show()
        }, to: menu)

        menu.addItem(.separator())
        addMenuItem(L10n.string("Action.Quit"), image: "power", action: {
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

        let targetItem = NSMenuItem(title: L10n.string("Control.TargetDevice"), action: nil, keyEquivalent: "")
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
            let item = NSMenuItem(title: L10n.string("Menu.NoDevicesFound"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return menu
        }

        for group in DeviceGroup.allCases {
            let devices = store.devices.filter { $0.group == group }
            guard !devices.isEmpty else { continue }

            let groupItem = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            groupItem.image = NSImage(systemSymbolName: group.symbolName, accessibilityDescription: nil)
            groupItem.state = devices.contains { $0.matches(project.deviceID) } ? .on : .off
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
            item.state = device.matches(project.deviceID) ? .on : .off
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
            button.image = NSImage(
                systemSymbolName: "xmark.octagon.fill",
                accessibilityDescription: L10n.string("Accessibility.LaunchPadFailed")
            )
            button.title = " " + L10n.string("StatusBar.Issue")
            button.contentTintColor = .systemRed
        } else if store.isBusy {
            button.image = NSImage(
                systemSymbolName: "bolt.fill",
                accessibilityDescription: L10n.string("Accessibility.LaunchPadWorking")
            )
            button.title = " " + L10n.string("StatusBar.Working")
            button.contentTintColor = .systemYellow
        } else if store.projects.contains(where: { $0.status == .running }) {
            button.image = NSImage(
                systemSymbolName: "stop.circle.fill",
                accessibilityDescription: L10n.string("Accessibility.LaunchPadAppRunning")
            )
            button.title = " " + L10n.string("Status.Running")
            button.contentTintColor = .systemGreen
        } else {
            button.image = NSImage(
                systemSymbolName: "play.square.stack",
                accessibilityDescription: L10n.string("Accessibility.LaunchPadForIOS")
            )
            button.title = " " + L10n.string("Action.Run")
            button.contentTintColor = nil
        }
    }

    private func primaryActionTitle(for project: ManagedProject) -> String {
        if project.status.isBusy { return L10n.format("Menu.BusyActionFormat", project.status.label) }
        return project.status == .running
            ? L10n.format("Menu.StopProjectFormat", project.name)
            : L10n.format("Menu.RunProjectFormat", project.name)
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
        window.title = L10n.string("Window.Title")
        window.center()
        window.contentView = NSHostingView(
            rootView: ContentView()
                .environmentObject(LaunchPadStore.shared)
        )
        window.makeKeyAndOrderFront(nil)
        manualWindow = window
    }
}
