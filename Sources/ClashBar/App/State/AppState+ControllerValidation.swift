import Foundation

@MainActor
extension AppState {
    func saveControllerSettings(reconnect: Bool = true) async {
        self.settingsErrorMessage = nil
        self.settingsSavedMessage = nil

        guard let normalizedController = self.validatedControllerAddress(self.controllerInput) else {
            self.settingsErrorMessage = tr("app.remote.controller.invalid")
            return
        }

        self.applyControllerCredentials(controller: normalizedController, secret: self.controllerSecretInput)
        self.persistControllerCredentials()
        let message = tr("app.remote.controller.saved")
        self.settingsSavedMessage = message
        self.scheduleSettingsFeedbackAutoClearIfNeeded(message: message)

        if reconnect {
            await self.reconnectRemoteController()
        }
    }

    func applyControllerCredentials(controller: String, secret: String?) {
        let normalizedController = self.normalizedControllerForClientAccess(controller)
        self.controller = normalizedController
        self.externalControllerDisplay = normalizedController
        self.controllerUIURL = self.makeControllerUIURL(normalizedController)
        self.controllerInput = normalizedController
        self.controllerSecret = self.normalizedControllerSecret(secret)
        self.controllerSecretInput = self.controllerSecret ?? ""
        self.ensureAPIClient()

        if let host = self.controllerHost(from: normalizedController), !self.isLoopbackHost(host) {
            self.appendExternalControllerWarningOnce(
                key: "remote:\(host.lowercased())",
                message: "[remote] controller host is \(host)")
        }
    }

    func validatedControllerAddress(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let components = self.parsedControllerComponents(from: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty
        else {
            return nil
        }
        guard scheme == "http" || scheme == "https" else {
            return nil
        }
        if let port = components.port, !(1...65535).contains(port) {
            return nil
        }
        return components.string ?? self.normalizedControllerAddress(trimmed)
    }

    func normalizedControllerAddress(_ value: String) -> String {
        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            return value
        }
        return "http://\(value)"
    }

    func controllerHost(from value: String) -> String? {
        self.parsedControllerComponents(from: value)?.host
    }

    private func parsedControllerComponents(from value: String) -> URLComponents? {
        URLComponents(string: self.normalizedControllerAddress(value))
    }

    private func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1"
    }

    private func appendExternalControllerWarningOnce(key: String, message: String) {
        if self.externalControllerWarningKeys.insert(key).inserted {
            self.appendLog(level: "warning", message: message)
        }
    }

    func normalizedControllerSecret(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "~" || trimmed.lowercased() == "null" {
            return nil
        }
        return trimmed
    }

    private func normalizedControllerForClientAccess(_ value: String) -> String {
        guard var components = self.parsedControllerComponents(from: value),
              let host = components.host
        else {
            return value
        }

        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let replacementHost: String
        switch normalizedHost {
        case "0.0.0.0":
            replacementHost = "127.0.0.1"
        case "::", "0:0:0:0:0:0:0:0":
            replacementHost = "::1"
        default:
            return value
        }

        components.host = replacementHost
        return components.string ?? value
    }
}
