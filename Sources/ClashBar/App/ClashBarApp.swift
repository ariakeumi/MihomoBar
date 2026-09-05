import AppKit
import SwiftUI

@main
struct ClashBarApp: App {
    @NSApplicationDelegateAdaptor(ClashBarAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandMenu("Connection") {
                Button(self.tr("ui.action.save_and_connect")) {
                    Task { await self.appDelegate.appState.saveControllerSettings() }
                }
                .keyboardShortcut("R", modifiers: [.command, .shift])
                .disabled(self.appDelegate.appState.isCoreActionProcessing)

                Button(self.tr("ui.action.reconnect")) {
                    Task { await self.appDelegate.appState.reconnectRemoteController() }
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(!self.appDelegate.appState.isPrimaryCoreActionEnabled)

                Button(self.tr("ui.action.disconnect")) {
                    self.appDelegate.appState.disconnectRemoteController()
                }
                .keyboardShortcut("D", modifiers: [.command, .shift])
                .disabled(!self.appDelegate.appState.isRemoteSessionActive)
            }

            CommandMenu("Panel") {
                Button(self.tr("ui.tab.proxy")) {
                    self.appDelegate.appState.setActiveMenuTab(.proxy)
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button(self.tr("ui.tab.rules")) {
                    self.appDelegate.appState.setActiveMenuTab(.rules)
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button(self.tr("ui.tab.activity")) {
                    self.appDelegate.appState.setActiveMenuTab(.activity)
                }
                .keyboardShortcut("3", modifiers: [.command])

                Button(self.tr("ui.tab.logs")) {
                    self.appDelegate.appState.setActiveMenuTab(.logs)
                }
                .keyboardShortcut("4", modifiers: [.command])

                Button(self.tr("ui.tab.system")) {
                    self.appDelegate.appState.setActiveMenuTab(.system)
                }
                .keyboardShortcut("5", modifiers: [.command])
            }

            CommandMenu("Actions") {
                Button(self.tr("ui.action.refresh")) {
                    Task { await self.appDelegate.appState.refreshActiveTab() }
                }
                .keyboardShortcut("K", modifiers: [.command, .shift])

                Button(self.tr("ui.action.copy_controller_address")) {
                    self.appDelegate.appState.copyControllerAddress()
                }
                .keyboardShortcut("C", modifiers: [.command, .option, .shift])

                Button(self.tr("ui.action.copy_all_logs")) {
                    self.appDelegate.appState.copyAllLogs()
                }
                .keyboardShortcut("L", modifiers: [.command, .option, .shift])

                Button(self.tr("ui.action.clear_all_logs")) {
                    self.appDelegate.appState.clearAllLogs()
                }
                .keyboardShortcut(.delete, modifiers: [.command, .option, .shift])
                .disabled(self.appDelegate.appState.errorLogs.isEmpty)
            }
        }
    }

    private func tr(_ key: String) -> String {
        L10n.t(key, language: self.appDelegate.appState.uiLanguage)
    }
}

@MainActor
final class ClashBarAppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let image = BrandIcon.image {
            NSApp.applicationIconImage = image
        }
        NSApp.setActivationPolicy(.accessory)
        self.statusItemController = StatusItemController(appState: self.appState)
    }

    func applicationWillTerminate(_ notification: Notification) {
        self.appState.shutdownForTermination()
        self.statusItemController?.shutdown()
        self.statusItemController = nil
    }
}
