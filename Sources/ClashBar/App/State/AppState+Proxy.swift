@MainActor
extension AppState {
    func switchMode(to target: CoreMode) async {
        if !self.isModeSwitchEnabled || self.modeSwitchInFlight || target == self.currentMode { return }
        self.modeSwitchInFlight = true
        defer { self.modeSwitchInFlight = false }

        self.currentMode = target

        do {
            try await self.modeSwitchTransport().requestNoResponse(.patchConfigs(body: ["mode": .string(target.rawValue)]))
        } catch {
            // Polling will reconcile remote state on the next refresh.
        }
    }

    func switchProxy(group: String, target: String) async {
        await self.runNoResponseAction(tr("log.action_name.switch_proxy", group, target)) {
            try await self.clientOrThrow().requestNoResponse(.switchProxy(name: group, target: target))
            await self.refreshProxyGroups()
        }
    }

    func refreshGroupLatency(_ group: ProxyGroup) async {
        self.groupLatencyLoading.insert(group.name)
        defer { self.groupLatencyLoading.remove(group.name) }

        let testURL = self.normalizedHealthcheckURL(group.testUrl) ?? self.defaultHealthcheckURL
        let timeout = self.normalizedHealthcheckTimeout(group.timeout) ?? self.defaultHealthcheckTimeoutMilliseconds
        await self.runRefresh {
            let client = try self.clientOrThrow()
            let response: GroupDelayMeasurement = try await client.request(
                .groupDelay(
                    name: group.name,
                    url: testURL,
                    timeout: timeout))
            let delays = response.values.filter { $0.value > 0 }
            self.groupLatencies[group.name] = delays
        }
    }

    func refreshAllGroupLatencies(includeHiddenGroups: Bool = false) async {
        let groups = includeHiddenGroups
            ? self.proxyGroups
            : self.proxyGroups.filter { $0.hidden != true }
        await withTaskGroup(of: Void.self) { taskGroup in
            for group in groups {
                taskGroup.addTask { [weak self] in
                    await self?.refreshGroupLatency(group)
                }
            }
        }
    }

    func delayText(group: String, node: String, fallbackToGroupHistory: Bool = false) -> String {
        guard let value = self.delayValue(
            group: group,
            node: node,
            fallbackToGroupHistory: fallbackToGroupHistory)
        else {
            return tr("ui.common.unknown")
        }
        if value == 0 { return tr("ui.common.timeout") }
        return tr("ui.common.latency_ms", value)
    }

    func delayValue(group: String, node: String, fallbackToGroupHistory: Bool = false) -> Int? {
        if let liveValue = self.groupLatencies[group]?[node] {
            return liveValue
        }
        if let historyValue = self.proxyHistoryLatestDelay[node] {
            return historyValue
        }
        if fallbackToGroupHistory {
            return self.proxyHistoryLatestDelay[group]
        }
        return nil
    }

    func makeControllerUIURL(_ controller: String) -> String {
        "\(normalizedControllerAddress(controller))/ui"
    }
}
