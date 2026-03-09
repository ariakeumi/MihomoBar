import Foundation

@MainActor
extension AppState {
    enum EditableCoreSetting: String, CaseIterable, Identifiable {
        case allowLan = "allow-lan"
        case ipv6
        case tcpConcurrent = "tcp-concurrent"
        case tunMode = "tun"
        case logLevel = "log-level"

        var id: String {
            self.rawValue
        }

        var configKey: String {
            self.rawValue
        }
    }

    private func boolStateKeyPath(for setting: EditableCoreSetting) -> ReferenceWritableKeyPath<AppState, Bool>? {
        switch setting {
        case .allowLan:
            \.settingsAllowLan
        case .ipv6:
            \.settingsIPv6
        case .tcpConcurrent:
            \.settingsTCPConcurrent
        case .tunMode:
            \.settingsTunEnabled
        case .logLevel:
            nil
        }
    }

    private func stringStateKeyPath(for setting: EditableCoreSetting) -> ReferenceWritableKeyPath<AppState, String>? {
        switch setting {
        case .logLevel:
            \.settingsLogLevel
        case .allowLan, .ipv6, .tcpConcurrent, .tunMode:
            nil
        }
    }

    func boolValue(for setting: EditableCoreSetting) -> Bool {
        guard let keyPath = self.boolStateKeyPath(for: setting) else {
            assertionFailure("Setting \(setting.configKey) does not store a Bool")
            return false
        }
        return self[keyPath: keyPath]
    }

    func stringValue(for setting: EditableCoreSetting) -> String {
        guard let keyPath = self.stringStateKeyPath(for: setting) else {
            assertionFailure("Setting \(setting.configKey) does not store a String")
            return ""
        }
        return self[keyPath: keyPath]
    }

    func applyEditableCoreSetting(_ setting: EditableCoreSetting, to value: Bool) async {
        guard let keyPath = self.boolStateKeyPath(for: setting) else {
            assertionFailure("Setting \(setting.configKey) does not accept Bool updates")
            return
        }
        if setting == .tunMode {
            self[keyPath: keyPath] = value
            await self.patchTunModeConfig(enabled: value)
            return
        }
        await self.applyBooleanSetting(keyPath, configKey: setting.configKey, value: value)
    }

    func applyEditableCoreSetting(_ setting: EditableCoreSetting, to value: String) async {
        guard let keyPath = self.stringStateKeyPath(for: setting) else {
            assertionFailure("Setting \(setting.configKey) does not accept String updates")
            return
        }

        let normalized = value.trimmed
        if setting == .logLevel, ConfigLogLevel(rawValue: normalized) == nil {
            self.settingsErrorMessage = tr("app.settings.error.invalid_log_level", value)
            self.settingsSavedMessage = nil
            return
        }

        self[keyPath: keyPath] = normalized
        await self.patchSingleConfig(setting.configKey, value: .string(normalized))
    }

    func applyProxyPorts(autoSaved: Bool = false) async {
        guard self.isRuntimeRunning else { return }
        guard let body = self.validatedPortPatchBody(
            fields: self.proxyPortFields,
            errorMessageKey: "app.settings.error.port_range",
            skipEmptyValues: false) else { return }

        let syncingKey = autoSaved ? "ports-auto" : "ports"
        let successMessage = autoSaved ? tr("app.settings.saved.ports_auto") : tr("app.settings.saved.ports")
        await self.patchConfigBody(body, syncingKey: syncingKey, successMessage: successMessage)
    }

    func scheduleProxyPortsAutoSaveIfNeeded() {
        guard self.isRuntimeRunning else { return }
        guard !self.suppressSettingsPersistence else { return }
        guard self.settingsSyncingKey == nil else { return }

        self.proxyPortsAutoSaveTask?.cancel()
        self.proxyPortsAutoSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 750_000_000)
            } catch {
                return
            }

            guard let self else { return }
            if Task.isCancelled { return }
            self.proxyPortsAutoSaveTask = nil
            await self.applyProxyPorts(autoSaved: true)
        }
    }

    func cancelProxyPortsAutoSave() {
        self.proxyPortsAutoSaveTask?.cancel()
        self.proxyPortsAutoSaveTask = nil
    }

    func syncEditableSettings(from config: ConfigSnapshot) {
        let incoming = EditableSettingsSnapshot(config: config)

        guard let previous = self.lastSyncedEditableSettings else {
            self.applyEditableSettingsSnapshotToUI(incoming)
            self.lastSyncedEditableSettings = incoming
            self.persistEditableSettingsSnapshot()
            return
        }

        self.suppressSettingsPersistence = true
        self.syncEditableFields(
            from: previous,
            to: incoming,
            fields: [
                (\.settingsAllowLan, \.allowLan),
                (\.settingsIPv6, \.ipv6),
                (\.settingsTCPConcurrent, \.tcpConcurrent),
                (\.settingsTunEnabled, \.tunEnabled),
            ])

        self.syncEditableFields(
            from: previous,
            to: incoming,
            fields: [
                (\.settingsLogLevel, \.logLevel),
                (\.settingsPort, \.port),
                (\.settingsSocksPort, \.socksPort),
                (\.settingsMixedPort, \.mixedPort),
                (\.settingsRedirPort, \.redirPort),
                (\.settingsTProxyPort, \.tproxyPort),
            ])
        self.suppressSettingsPersistence = false

        self.lastSyncedEditableSettings = incoming
        self.persistEditableSettingsSnapshot()
    }

    func currentEditableSettingsSnapshot() -> EditableSettingsSnapshot {
        EditableSettingsSnapshot(
            allowLan: self.settingsAllowLan,
            ipv6: self.settingsIPv6,
            tcpConcurrent: self.settingsTCPConcurrent,
            tunEnabled: self.settingsTunEnabled,
            logLevel: self.settingsLogLevel,
            port: self.settingsPort,
            socksPort: self.settingsSocksPort,
            mixedPort: self.settingsMixedPort,
            redirPort: self.settingsRedirPort,
            tproxyPort: self.settingsTProxyPort)
    }

    func effectiveMixedPort() -> Int {
        if self.mixedPort > 0 {
            return self.mixedPort
        }
        let trimmed = self.settingsMixedPort.trimmed
        if let value = Int(trimmed), (1...65535).contains(value) {
            return value
        }
        return 7890
    }

    func applyEditableSettingsSnapshotToUI(_ snapshot: EditableSettingsSnapshot) {
        self.suppressSettingsPersistence = true
        self.settingsAllowLan = snapshot.allowLan
        self.settingsIPv6 = snapshot.ipv6
        self.settingsTCPConcurrent = snapshot.tcpConcurrent
        self.settingsTunEnabled = snapshot.tunEnabled
        self.settingsLogLevel = snapshot.logLevel
        self.settingsPort = snapshot.port
        self.settingsSocksPort = snapshot.socksPort
        self.settingsMixedPort = snapshot.mixedPort
        self.settingsRedirPort = snapshot.redirPort
        self.settingsTProxyPort = snapshot.tproxyPort
        self.suppressSettingsPersistence = false
    }

    func patchTunModeConfig(enabled: Bool) async {
        _ = await self.patchConfigBody(
            ["tun": .object(["enable": .bool(enabled)])],
            syncingKey: EditableCoreSetting.tunMode.configKey,
            successMessage: tr("app.settings.saved.single_key", EditableCoreSetting.tunMode.configKey))
    }

    func applySettingBool(key: String, value: Bool) async {
        await self.patchSingleConfig(key, value: .bool(value))
    }

    func patchSingleConfig(_ key: String, value: ConfigPatchValue) async {
        _ = await self.patchConfigBody(
            [key: value],
            syncingKey: key,
            successMessage: tr("app.settings.saved.single_key", key))
    }

    @discardableResult
    func patchConfigBody(_ body: [String: ConfigPatchValue], syncingKey: String, successMessage: String) async -> Bool {
        self.cancelProxyPortsAutoSave()
        self.settingsFeedbackClearTask?.cancel()
        self.settingsFeedbackClearTask = nil
        self.settingsSyncingKey = syncingKey
        self.settingsErrorMessage = nil
        self.settingsSavedMessage = nil
        defer { self.settingsSyncingKey = nil }

        do {
            let payload = body.mapValues(\.jsonValue)
            try await self.settingsPatchTransport().requestNoResponse(.patchConfigs(body: payload))
            self.settingsSavedMessage = successMessage
            self.scheduleSettingsFeedbackAutoClearIfNeeded(message: successMessage)
            await self.refreshFromAPI(includeSlowCalls: false)
            return true
        } catch {
            let message = tr("app.settings.error.save_failed", syncingKey, error.localizedDescription)
            self.settingsErrorMessage = message
            self.settingsSavedMessage = nil
            await self.refreshFromAPI(includeSlowCalls: false)
            return false
        }
    }

    func scheduleSettingsFeedbackAutoClearIfNeeded(message: String) {
        guard message.trimmedNonEmpty != nil else { return }

        self.settingsFeedbackClearTask?.cancel()
        self.settingsFeedbackClearTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }

            guard let self else { return }
            if self.settingsSavedMessage == message {
                self.settingsSavedMessage = nil
            }
        }
    }

    func clientOrThrow() throws -> MihomoAPIClient {
        if self.apiClient == nil {
            self.ensureAPIClient()
        }
        if let apiClient {
            return apiClient
        }
        throw APIError.invalidURL
    }

    func modeSwitchTransport() throws -> MihomoAPITransporting {
        try self.resolvedTransport(override: self.modeSwitchTransportOverride)
    }

    func settingsPatchTransport() throws -> MihomoAPITransporting {
        try self.resolvedTransport(override: self.settingsPatchTransportOverride)
    }

    private func applyBooleanSetting(
        _ keyPath: ReferenceWritableKeyPath<AppState, Bool>,
        configKey: String,
        value: Bool) async
    {
        self[keyPath: keyPath] = value
        await self.applySettingBool(key: configKey, value: value)
    }

    private func validatedPort(_ textValue: String, key: String, errorMessageKey: String) -> Int? {
        let trimmed = textValue.trimmed
        guard let intValue = Int(trimmed), (0...65535).contains(intValue) else {
            self.settingsErrorMessage = tr(errorMessageKey, key)
            self.settingsSavedMessage = nil
            return nil
        }
        return intValue
    }

    private var proxyPortFields: [(key: String, value: String)] {
        [
            ("port", self.settingsPort),
            ("socks-port", self.settingsSocksPort),
            ("mixed-port", self.settingsMixedPort),
            ("redir-port", self.settingsRedirPort),
            ("tproxy-port", self.settingsTProxyPort),
        ]
    }

    private func validatedPortPatchBody(
        fields: [(key: String, value: String)],
        errorMessageKey: String,
        skipEmptyValues: Bool) -> [String: ConfigPatchValue]?
    {
        var body: [String: ConfigPatchValue] = [:]
        for field in fields {
            let trimmedValue = field.value.trimmed
            if skipEmptyValues, trimmedValue.isEmpty {
                continue
            }
            guard let intValue = self.validatedPort(
                trimmedValue,
                key: field.key,
                errorMessageKey: errorMessageKey) else { return nil }
            body[field.key] = .int(intValue)
        }
        return body
    }

    private func syncEditableFields<Value: Equatable>(
        from previous: EditableSettingsSnapshot,
        to incoming: EditableSettingsSnapshot,
        fields: [(ReferenceWritableKeyPath<AppState, Value>, KeyPath<EditableSettingsSnapshot, Value>)])
    {
        for (stateKeyPath, snapshotKeyPath) in fields {
            guard self[keyPath: stateKeyPath] == previous[keyPath: snapshotKeyPath] else { continue }
            self[keyPath: stateKeyPath] = incoming[keyPath: snapshotKeyPath]
        }
    }

    private func resolvedTransport(override: MihomoAPITransporting?) throws -> MihomoAPITransporting {
        if let override {
            return override
        }
        return try self.clientOrThrow()
    }
}
