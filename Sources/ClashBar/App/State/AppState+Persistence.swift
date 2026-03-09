import Foundation

@MainActor
extension AppState {
    func ensureAPIClient() {
        guard let normalized = self.validatedControllerAddress(self.controller) else {
            self.apiClient = nil
            return
        }

        self.controller = normalized
        self.externalControllerDisplay = normalized
        self.controllerUIURL = self.makeControllerUIURL(normalized)

        if let apiClient {
            apiClient.updateCredentials(controller: normalized, secret: self.controllerSecret)
        } else {
            self.apiClient = MihomoAPIClient(controller: normalized, secret: self.controllerSecret)
        }
    }

    func persistEditableSettingsSnapshot() {
        guard !self.suppressSettingsPersistence else { return }
        let snapshot = self.currentEditableSettingsSnapshot()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        self.defaults.set(data, forKey: self.editableSettingsSnapshotKey)
    }

    func loadPersistedEditableSettingsSnapshot() -> EditableSettingsSnapshot? {
        guard let data = self.defaults.data(forKey: self.editableSettingsSnapshotKey) else { return nil }
        return try? JSONDecoder().decode(EditableSettingsSnapshot.self, from: data)
    }

    func persistOpenWrtTrafficSettings() {
        let snapshot = OpenWrtTrafficSettingsSnapshot(
            enabled: self.menuBarShowsOpenWrtTraffic,
            endpoint: self.openWrtEndpointInput,
            interfaceName: self.openWrtInterfaceInput,
            username: self.openWrtUsernameInput,
            password: self.openWrtPasswordInput)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        self.defaults.set(data, forKey: self.openWrtTrafficSettingsKey)
    }

    func loadPersistedOpenWrtTrafficSettings() -> OpenWrtTrafficSettingsSnapshot {
        guard let data = self.defaults.data(forKey: self.openWrtTrafficSettingsKey),
              let snapshot = try? JSONDecoder().decode(OpenWrtTrafficSettingsSnapshot.self, from: data)
        else {
            return OpenWrtTrafficSettingsSnapshot(
                enabled: false,
                endpoint: "",
                interfaceName: "",
                username: "root",
                password: "")
        }
        return snapshot
    }

    func applyOpenWrtTrafficSettingsSnapshot(_ snapshot: OpenWrtTrafficSettingsSnapshot) {
        self.openWrtEndpointInput = snapshot.endpoint
        self.openWrtInterfaceInput = snapshot.interfaceName
        self.openWrtUsernameInput = snapshot.username
        self.openWrtPasswordInput = snapshot.password
        self.menuBarShowsOpenWrtTraffic = snapshot.enabled
    }

    func loadPersistedControllerAddress() -> String {
        let stored = self.defaults.string(forKey: self.controllerAddressKey) ?? "http://127.0.0.1:9090"
        return self.validatedControllerAddress(stored) ?? "http://127.0.0.1:9090"
    }

    func loadPersistedControllerSecret() -> String? {
        self.normalizedControllerSecret(self.defaults.string(forKey: self.controllerSecretKey))
    }

    func persistControllerCredentials() {
        self.defaults.set(self.controller, forKey: self.controllerAddressKey)
        if let secret = self.normalizedControllerSecret(self.controllerSecret) {
            self.defaults.set(secret, forKey: self.controllerSecretKey)
        } else {
            self.defaults.removeObject(forKey: self.controllerSecretKey)
        }
    }

    func loadPersistedUILanguage() -> AppLanguage {
        if let raw = self.defaults.string(forKey: self.uiLanguageKey),
           let language = AppLanguage(rawValue: raw)
        {
            return language
        }
        self.defaults.set(AppLanguage.zhHans.rawValue, forKey: self.uiLanguageKey)
        return .zhHans
    }

    func loadPersistedAppearanceMode() -> AppAppearanceMode {
        if let raw = self.defaults.string(forKey: self.appearanceModeKey),
           let mode = AppAppearanceMode(rawValue: raw)
        {
            return mode
        }
        self.defaults.set(AppAppearanceMode.system.rawValue, forKey: self.appearanceModeKey)
        return .system
    }

    func persistTrafficIndicatorUnit() {
        self.defaults.set(self.trafficIndicatorUnit.rawValue, forKey: self.trafficIndicatorUnitKey)
    }

    func loadPersistedTrafficIndicatorUnit() -> TrafficIndicatorUnit {
        if let raw = self.defaults.string(forKey: self.trafficIndicatorUnitKey),
           let unit = TrafficIndicatorUnit(rawValue: raw)
        {
            return unit
        }
        self.defaults.set(TrafficIndicatorUnit.byte.rawValue, forKey: self.trafficIndicatorUnitKey)
        return .byte
    }

    func persistProxyGroupFontSize() {
        self.defaults.set(self.proxyGroupFontSize.rawValue, forKey: self.proxyGroupFontSizeKey)
    }

    func loadPersistedProxyGroupFontSize() -> ProxyGroupFontSize {
        if let raw = self.defaults.string(forKey: self.proxyGroupFontSizeKey),
           let size = ProxyGroupFontSize(rawValue: raw)
        {
            return size
        }
        self.defaults.set(ProxyGroupFontSize.medium.rawValue, forKey: self.proxyGroupFontSizeKey)
        return .medium
    }
}
