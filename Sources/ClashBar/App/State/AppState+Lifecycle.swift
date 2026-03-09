import AppKit
import Foundation

@MainActor
extension AppState {
    func connectRemoteController() async {
        guard !self.isCoreActionProcessing else { return }
        guard self.isControllerConfigured else {
            self.settingsErrorMessage = tr("app.remote.controller.invalid")
            self.connectionState = .failed
            self.apiStatus = .failed
            self.statusText = "Failed"
            return
        }

        self.coreActionState = .starting
        self.connectionState = .connecting
        self.statusText = "Connecting"
        self.apiStatus = .unknown
        self.settingsErrorMessage = nil
        defer { self.coreActionState = .idle }

        self.cancelProviderRefresh(reason: "superseded")
        self.cancelPolling()
        self.resetTrafficPresentation()
        self.ensureAPIClient()

        do {
            let client = try self.clientOrThrow()
            let info: VersionInfo = try await client.request(.version)
            self.version = info.version
            self.connectionState = .connected
            self.apiStatus = .healthy
            self.statusText = "Connected"

            await self.refreshFromAPI(includeSlowCalls: true)
            self.connectionState = .connected
            self.statusText = self.apiStatus == .healthy ? "Connected" : "Degraded"
        } catch {
            self.connectionState = .failed
            self.apiStatus = .failed
            self.statusText = "Failed"
            self.appendLog(level: "error", message: tr("app.remote.connection_failed", error.localizedDescription))
        }
    }

    func reconnectRemoteController() async {
        guard !self.isCoreActionProcessing else { return }
        self.disconnectRemoteController(resetCoreActionState: false)
        await self.connectRemoteController()
    }

    func disconnectRemoteController(resetCoreActionState: Bool = true) {
        if resetCoreActionState {
            self.coreActionState = .stopping
        }
        defer {
            if resetCoreActionState {
                self.coreActionState = .idle
            }
        }

        self.cancelProxyPortsAutoSave()
        self.cancelProviderRefresh(reason: "superseded")
        self.cancelPolling()
        self.connectionState = .disconnected
        self.apiStatus = .unknown
        self.statusText = "Disconnected"
        self.resetTrafficPresentation()
        self.releasePanelCachedData()
    }

    func startCore(trigger _: StartTrigger = .manual) async {
        await self.connectRemoteController()
    }

    func stopCore(trigger _: StopTrigger = .manual) async {
        self.disconnectRemoteController()
    }

    func performPrimaryCoreAction() async {
        await self.reconnectRemoteController()
    }

    func setUILanguage(_ language: AppLanguage) {
        guard self.uiLanguage != language else { return }
        self.uiLanguage = language
        self.defaults.set(language.rawValue, forKey: self.uiLanguageKey)
    }

    func setAppearanceMode(_ mode: AppAppearanceMode) {
        guard self.appearanceMode != mode else { return }
        self.appearanceMode = mode
        self.defaults.set(mode.rawValue, forKey: self.appearanceModeKey)
        self.applyAppAppearance()
    }

    func quitApp() async {
        self.prepareForTermination()
        NSApplication.shared.terminate(nil)
    }

    func shutdownForTermination() {
        self.prepareForTermination()
    }

    private func prepareForTermination() {
        self.stopOpenWrtTrafficPolling(resetTraffic: false)
        self.cancelProxyPortsAutoSave()
        self.cancelProviderRefresh(reason: "superseded")
        self.cancelPolling()
    }

    func applyAppAppearance() {
        switch self.appearanceMode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func normalizeMode(_ raw: String?) -> CoreMode? {
        guard let raw else { return nil }
        return CoreMode(rawValue: raw.lowercased())
    }
}
