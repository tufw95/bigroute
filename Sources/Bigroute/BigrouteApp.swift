import AppKit
#if canImport(ServiceManagement)
import ServiceManagement
#endif
#if SWIFT_PACKAGE
import BigrouteCore
#endif
import SwiftUI

@main
struct BigrouteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(delegate.monitor)
                .environment(delegate.updateController)
                .frame(width: 560, height: 620)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = QuotaMonitor()
    let updateController = UpdateController()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMenuBarItem()
        updateController.onAvailabilityChange = { [weak self] isAvailable in
            self?.updateMenuBarIcon(updateAvailable: isAvailable)
        }
        enableLaunchAtLogin()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        monitor.start()
    }

    private func enableLaunchAtLogin() {
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *), SMAppService.mainApp.status == .notRegistered {
            try? SMAppService.mainApp.register()
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        monitor.stop()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first,
              let scheme = url.scheme?.lowercased(),
              scheme == "bigroute" || scheme == "routerquota" else { return }
        if url.host == "refresh" {
            monitor.refresh(force: true)
            showPopover()
            return
        }
        if url.host == "settings" {
            popover?.performClose(nil)
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                // Keep widget deep links on the native popover path. The
                // SettingsLink inside it opens the SwiftUI Settings scene.
                self.showPopover()
            }
            return
        }
        guard url.host == "provider",
              let providerID = UUID(uuidString: url.lastPathComponent) else { return }
        monitor.selectProvider(id: providerID)
        showPopover()
    }

    private func installMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)

        let panel = NSPopover()
        panel.behavior = .transient
        panel.animates = true
        let hostingController = NSHostingController(
            rootView: DashboardView()
                .environment(monitor)
                .environment(updateController)
        )
        hostingController.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hostingController

        statusItem = item
        popover = panel
        updateMenuBarIcon(updateAvailable: updateController.isUpdateAvailable)
    }

    private func updateMenuBarIcon(updateAvailable: Bool) {
        let description = updateAvailable ? "Bigroute update available" : "Bigroute"
        guard let button = statusItem?.button,
              let markURL = Bundle.main.url(forResource: "BigrouteMark", withExtension: "svg"),
              let mark = NSImage(contentsOf: markURL) else { return }

        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            mark.draw(in: NSRect(x: 0, y: 0, width: 17, height: 17))
            if updateAvailable {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 13, y: 13, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = true
        button.image = image
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover(relativeTo: button)
        }
    }

    @objc private func workspaceDidWake() {
        monitor.refresh()
    }

    private func showPopover(relativeTo button: NSStatusBarButton? = nil) {
        guard let popover, let anchor = button ?? statusItem?.button else { return }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }
}
