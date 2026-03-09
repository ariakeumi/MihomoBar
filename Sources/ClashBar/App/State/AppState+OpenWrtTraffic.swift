import Foundation

@MainActor
extension AppState {
    func updateOpenWrtTrafficPolling() {
        let shouldPoll = self.menuBarShowsOpenWrtTraffic && self.statusBarDisplayMode != .iconOnly
        guard shouldPoll else {
            self.stopOpenWrtTrafficPolling(resetTraffic: true)
            return
        }

        guard self.openWrtTrafficPollTask == nil else { return }
        self.openWrtTrafficPollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshOpenWrtMenuBarTraffic()
                do {
                    try await Task.sleep(nanoseconds: self.openWrtTrafficPollIntervalNanoseconds)
                } catch {
                    return
                }
            }
        }
    }

    func stopOpenWrtTrafficPolling(resetTraffic: Bool) {
        self.openWrtTrafficPollTask?.cancel()
        self.openWrtTrafficPollTask = nil
        Task { await self.openWrtTrafficService.reset() }

        if resetTraffic, self.openWrtTraffic != TrafficSnapshot(up: 0, down: 0) {
            self.openWrtTraffic = TrafficSnapshot(up: 0, down: 0)
        }
    }

    func refreshOpenWrtMenuBarTraffic() async {
        guard self.menuBarShowsOpenWrtTraffic else {
            if self.openWrtTraffic != TrafficSnapshot(up: 0, down: 0) {
                self.openWrtTraffic = TrafficSnapshot(up: 0, down: 0)
            }
            return
        }

        guard let configuration = self.currentOpenWrtTrafficConfiguration() else {
            if self.openWrtTraffic != TrafficSnapshot(up: 0, down: 0) {
                self.openWrtTraffic = TrafficSnapshot(up: 0, down: 0)
            }
            await self.openWrtTrafficService.reset()
            return
        }

        do {
            self.openWrtTraffic = try await self.openWrtTrafficService.pollTraffic(configuration: configuration)
            self.lastOpenWrtTrafficErrorMessage = nil
            self.lastOpenWrtTrafficErrorAt = nil
        } catch {
            self.openWrtTraffic = TrafficSnapshot(up: 0, down: 0)
            self.logOpenWrtTrafficFailureIfNeeded(error)
        }
    }

    func currentOpenWrtTrafficConfiguration() -> OpenWrtTrafficConfiguration? {
        guard self.menuBarShowsOpenWrtTraffic else { return nil }
        guard let endpoint = self.normalizedOpenWrtEndpoint(self.openWrtEndpointInput),
              let interfaceName = self.openWrtInterfaceInput.trimmedNonEmpty,
              let username = self.openWrtUsernameInput.trimmedNonEmpty,
              let password = self.openWrtPasswordInput.trimmedNonEmpty
        else {
            return nil
        }

        return OpenWrtTrafficConfiguration(
            endpoint: endpoint,
            interfaceName: interfaceName,
            username: username,
            password: password)
    }

    func normalizedOpenWrtEndpoint(_ value: String) -> String? {
        let trimmed = value.trimmed
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let components = URLComponents(string: normalized),
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

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty {
            return "\(scheme)://\(host)\(components.port.map { ":\($0)" } ?? "")"
        }

        return components.string
    }

    private func logOpenWrtTrafficFailureIfNeeded(_ error: Error) {
        let message = error.localizedDescription
        let now = Date()

        if let lastAt = self.lastOpenWrtTrafficErrorAt,
           let lastMessage = self.lastOpenWrtTrafficErrorMessage,
           now.timeIntervalSince(lastAt) < self.openWrtTrafficErrorLogThrottleInterval,
           lastMessage == message
        {
            return
        }

        self.lastOpenWrtTrafficErrorAt = now
        self.lastOpenWrtTrafficErrorMessage = message
        self.appendLog(level: "error", message: tr("log.openwrt.traffic.failed", message))
    }
}
