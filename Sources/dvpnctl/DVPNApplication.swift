import AppKit
import Darwin
import SwiftUI

@main
enum DVPNApplication {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.dropFirst().first == "--vpn-worker" {
            guard geteuid() == 0, arguments.count == 4, let user = uid_t(arguments[3]),
                  PrivilegePolicy.isAdministrator(user) else { exit(64) }
            do {
                let socket = try LocalSocket.connect(path: arguments[2], expectedUser: user)
                let executable = VPNWorker.findExecutable()
                if let executable, !PrivilegePolicy.canAuthorizeExecutable(at: executable, for: user) {
                    try? socket.send(Data("dFortiClient: openfortivpn 的安装路径不受信任。\n".utf8))
                    exit(1)
                }
                exit(VPNWorker.run(socket: socket, executable: executable))
            } catch {
                exit(1)
            }
        }

        let app = NSApplication.shared
        let delegate = MenuBarController()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

private final class SettingsWindow: NSWindow {
    override func miniaturize(_ sender: Any?) { orderOut(sender) }
}

private final class MenuBarController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = ConnectionModel()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let connectionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var window: NSWindow?
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.addItem(statusLabel)
        menu.addItem(.separator())
        menu.addItem(item("打开 dFortiClient", #selector(showWindow), key: "o"))
        connectionItem.target = self
        menu.addItem(connectionItem)
        menu.addItem(.separator())
        menu.addItem(item("退出 dFortiClient", #selector(quit), key: "q"))
        statusItem.menu = menu

        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(item("最小化到菜单栏", #selector(hideWindow), key: "m"))
        appMenu.addItem(item("退出 dFortiClient", #selector(quit), key: "q"))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu

        model.onStateChanged = { [weak self] in self?.refreshStatus() }
        model.onSessionEnded = { [weak self] in
            guard let self, self.quitting else { return }
            if let notice = self.model.notice {
                let alert = NSAlert()
                alert.messageText = "VPN 未正常断开"
                alert.informativeText = notice
                alert.addButton(withTitle: "退出 dFortiClient")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        refreshStatus()
        showWindow()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isActive else { return .terminateNow }
        quitting = true
        model.disconnect()
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshBackgroundState()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    private func item(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func refreshStatus() {
        statusLabel.title = "\(model.activeProfileName ?? "VPN") · \(model.status.rawValue)"
        if model.isActive {
            connectionItem.submenu = nil
            connectionItem.title = "断开 VPN"
            connectionItem.action = #selector(disconnectVPN)
        } else {
            let submenu = NSMenu(title: "连接 VPN")
            for profile in model.profiles {
                let choice = item(profile.name, #selector(connectVPN(_:)), key: "")
                choice.representedObject = profile.id.uuidString
                submenu.addItem(choice)
            }
            if model.profiles.isEmpty {
                submenu.addItem(item("添加 VPN 配置…", #selector(showWindow), key: ""))
            }
            connectionItem.action = nil
            connectionItem.title = "连接 VPN"
            connectionItem.submenu = submenu
        }
        let symbol: String
        switch model.status {
        case .connected: symbol = "lock.shield.fill"
        case .idle: symbol = "lock.shield"
        default: symbol = "ellipsis.circle"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: statusLabel.title)
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "dFortiClient · \(statusLabel.title)"
    }

    @objc private func showWindow() {
        model.refreshBackgroundState()
        if window == nil {
            let panel = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 630, height: 710),
                                       styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                       backing: .buffered, defer: false)
            panel.title = "dFortiClient"
            panel.contentViewController = NSHostingController(rootView: ConnectionView(model: model))
            panel.contentMinSize = NSSize(width: 565, height: 675)
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.center()
            window = panel
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func hideWindow() { window?.orderOut(nil) }

    @objc private func connectVPN(_ sender: NSMenuItem) {
        guard let representedID = sender.representedObject as? String,
              let id = UUID(uuidString: representedID) else { return }
        if !model.connectSavedProfile(id) { showWindow() }
    }

    @objc private func disconnectVPN() { model.disconnect() }

    @objc private func quit() { NSApp.terminate(nil) }
}
