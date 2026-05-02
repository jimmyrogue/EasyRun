import AppKit
import Combine
import Foundation
import SwiftUI
import UserNotifications

private struct MenuProjectSnapshot: Equatable {
    var id: UUID
    var name: String
    var scheme: String
    var schemes: [String]?
    var configuration: String
    var deviceID: String
    var deviceName: String
    var status: ProjectStatus
    var statusMessage: String

    init(project: ManagedProject) {
        id = project.id
        name = project.name
        scheme = project.scheme
        schemes = project.schemes
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
        sender.setActivationPolicy(.accessory)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowPresenter.show()
        return false
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

        if let project = store.projects.first {
            addProjectHeader(for: project, to: menu)
            menu.addItem(.separator())
            addProjectActions(for: project, store: store, to: menu)
        } else {
            let title = NSMenuItem(title: L10n.string("Window.Title"), action: nil, keyEquivalent: "")
            title.image = NSImage(
                systemSymbolName: "play.square.stack",
                accessibilityDescription: L10n.string("Accessibility.LaunchPadForIOS")
            )
            title.isEnabled = false
            menu.addItem(title)
            menu.addItem(.separator())

            let empty = NSMenuItem(title: L10n.string("Menu.NoProjectsYet"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        menu.addItem(.separator())

        let otherItem = NSMenuItem(title: L10n.string("Menu.Other"), action: nil, keyEquivalent: "")
        otherItem.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        otherItem.submenu = otherMenu(for: store.projects.first, store: store)
        menu.addItem(otherItem)

        statusItem.menu = menu
    }

    private func addProjectHeader(for project: ManagedProject, to menu: NSMenu) {
        let item = NSMenuItem(title: project.name, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "app.badge", accessibilityDescription: nil)
        item.toolTip = "\(project.status.label): \(project.statusMessage)\n\(project.summaryLine)"
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addProjectActions(for project: ManagedProject, store: LaunchPadStore, to menu: NSMenu) {
        addProjectActionItem(
            runToggleTitle(for: project),
            image: runToggleIcon(for: project),
            keyEquivalent: "1",
            isEnabled: canToggleRun(project, store: store),
            project: project,
            to: menu
        ) { store, currentProject in
            if currentProject.status == .running {
                await store.stop(currentProject)
            } else {
                await store.run(currentProject)
            }
        }

        addProjectActionItem(
            L10n.string("Action.Restart"),
            image: "arrow.clockwise.circle.fill",
            keyEquivalent: "2",
            isEnabled: canRestart(project, store: store),
            project: project,
            to: menu
        ) { store, currentProject in
            if currentProject.status == .running {
                await store.stop(currentProject)
            }
            await store.run(currentProject)
        }
    }

    private func otherMenu(for project: ManagedProject?, store: LaunchPadStore) -> NSMenu {
        let menu = NSMenu()

        if let project {
            let targetItem = NSMenuItem(
                title: L10n.format("Menu.TargetFormat", project.scheme.trimmed.isEmpty ? L10n.string("Menu.NoTargetSelected") : project.scheme),
                action: nil,
                keyEquivalent: ""
            )
            targetItem.image = NSImage(systemSymbolName: "scope", accessibilityDescription: nil)
            targetItem.submenu = targetMenu(for: project, store: store)
            targetItem.isEnabled = !project.status.isBusy
            targetItem.toolTip = project.name
            menu.addItem(targetItem)

            let deviceItem = NSMenuItem(
                title: L10n.format("Menu.DeviceFormat", project.displayDeviceName),
                action: nil,
                keyEquivalent: ""
            )
            deviceItem.image = NSImage(systemSymbolName: deviceIcon(for: project), accessibilityDescription: nil)
            deviceItem.submenu = deviceMenu(for: project, store: store)
            deviceItem.isEnabled = !project.status.isBusy
            deviceItem.toolTip = project.name
            menu.addItem(deviceItem)

            menu.addItem(.separator())
        }

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

        return menu
    }

    private func addProjectActionItem(
        _ title: String,
        image: String,
        keyEquivalent: String,
        isEnabled: Bool,
        project: ManagedProject,
        to menu: NSMenu,
        operation: @escaping @MainActor (LaunchPadStore, ManagedProject) async -> Void
    ) {
        let token = MenuAction { [weak store] in
            guard let store,
                  let currentProject = store.projects.first(where: { $0.id == project.id }) else { return }
            Task {
                await operation(store, currentProject)
            }
        }
        actions.append(token)

        let item = NSMenuItem(
            title: title,
            action: #selector(MenuAction.runAction),
            keyEquivalent: keyEquivalent
        )
        item.target = token
        item.image = NSImage(systemSymbolName: image, accessibilityDescription: nil)
        item.isEnabled = isEnabled
        item.toolTip = "\(project.status.label): \(project.statusMessage)\n\(project.summaryLine)"
        menu.addItem(item)
    }

    private func targetMenu(for project: ManagedProject, store: LaunchPadStore) -> NSMenu {
        let menu = NSMenu()
        let schemes = project.availableSchemes

        if schemes.isEmpty {
            let item = NSMenuItem(title: L10n.string("Menu.NoTargetsFound"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return menu
        }

        for scheme in schemes {
            let token = MenuAction { [weak store] in
                store?.updateScheme(project.id, value: scheme)
            }
            actions.append(token)

            let item = NSMenuItem(
                title: scheme,
                action: #selector(MenuAction.runAction),
                keyEquivalent: ""
            )
            item.target = token
            item.image = NSImage(systemSymbolName: "scope", accessibilityDescription: nil)
            item.state = scheme == project.scheme ? .on : .off
            item.isEnabled = !project.status.isBusy
            menu.addItem(item)
        }

        return menu
    }

    private func deviceMenu(for project: ManagedProject, store: LaunchPadStore) -> NSMenu {
        let menu = NSMenu()

        if store.devices.isEmpty {
            let item = NSMenuItem(title: L10n.string("Menu.NoDevicesFound"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return menu
        }

        var hasAddedGroup = false
        for group in DeviceGroup.allCases {
            let devices = store.devices.filter { $0.group == group }
            guard !devices.isEmpty else { continue }

            let groupItem = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            groupItem.image = NSImage(systemSymbolName: group.symbolName, accessibilityDescription: nil)
            groupItem.isEnabled = false

            if hasAddedGroup {
                menu.addItem(.separator())
            }
            menu.addItem(groupItem)
            hasAddedGroup = true

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

    private func runToggleTitle(for project: ManagedProject) -> String {
        if project.status.isBusy { return L10n.format("Menu.BusyActionFormat", project.status.label) }
        return project.status == .running ? L10n.string("Action.Stop") : L10n.string("Action.Start")
    }

    private func runToggleIcon(for project: ManagedProject) -> String {
        if project.status.isBusy { return "bolt.fill" }
        return project.status == .running ? "stop.fill" : "play.fill"
    }

    private func canToggleRun(_ project: ManagedProject, store: LaunchPadStore) -> Bool {
        if project.status.isBusy { return false }
        if project.status == .running { return true }
        return hasRunnableDestination(project, store: store)
    }

    private func canRestart(_ project: ManagedProject, store: LaunchPadStore) -> Bool {
        project.status == .running && hasRunnableDestination(project, store: store)
    }

    private func hasRunnableDestination(_ project: ManagedProject, store: LaunchPadStore) -> Bool {
        return !store.devices.isEmpty
            && !project.deviceID.trimmed.isEmpty
            && !project.scheme.trimmed.isEmpty
    }

    private func deviceIcon(for project: ManagedProject) -> String {
        if project.deviceKind == .physical {
            return DeviceGroup.physical.symbolName
        }

        switch project.devicePlatform {
        case .tvOS:
            return DeviceGroup.appleTV.symbolName
        case .watchOS:
            return DeviceGroup.appleWatch.symbolName
        case .visionOS:
            return DeviceGroup.vision.symbolName
        case .iOS:
            return project.deviceName.localizedCaseInsensitiveContains("iPad")
                ? DeviceGroup.iPad.symbolName
                : DeviceGroup.iPhone.symbolName
        case .unknown:
            return DeviceGroup.other.symbolName
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
        NSApp.setActivationPolicy(.regular)
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
