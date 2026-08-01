import AppKit
#if canImport(ServiceManagement)
import ServiceManagement
#endif
#if SWIFT_PACKAGE
import RouterQuotaCore
#endif
import SwiftUI

@main
struct RouterQuotaApp: App {
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
        guard let url = urls.first, url.scheme == "routerquota" else { return }
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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)

        let panel = NSPopover()
        panel.behavior = .transient
        panel.animates = true
        panel.contentSize = NSSize(width: 700, height: 790)
        panel.contentViewController = NSHostingController(
            rootView: DashboardView()
                .environment(monitor)
                .environment(updateController)
        )

        statusItem = item
        popover = panel
        updateMenuBarIcon(updateAvailable: updateController.isUpdateAvailable)
    }

    private func updateMenuBarIcon(updateAvailable: Bool) {
        let symbol = updateAvailable ? "arrow.down.circle.fill" : "gauge.with.dots.needle.33percent"
        let description = updateAvailable ? "Router Quota update available" : "Router Quota"
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
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
        monitor.refresh()
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }
}
