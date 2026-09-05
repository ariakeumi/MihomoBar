import Foundation

@MainActor
extension AppState {
    func startPolling() {
        self.updateDataAcquisitionPolicy()
    }

    func cancelPolling() {
        self.teardownStreams()
    }

    private func teardownStreams() {
        self.mediumFrequencyTask?.cancel()
        self.lowFrequencyTask?.cancel()
        for kind in StreamKind.allCases {
            self.cancelStream(kind)
        }
        self.mediumFrequencyTask = nil
        self.lowFrequencyTask = nil
        self.currentConnectionsStreamIntervalMilliseconds = nil
    }

    private func startPeriodicTask(
        intervalProvider: @escaping (AppState) -> UInt64,
        operation: @escaping (AppState) async -> Void) -> Task<Void, Never>
    {
        Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await operation(self)
                do {
                    let interval = max(1_000_000_000, intervalProvider(self))
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
            }
        }
    }

    private func ensurePeriodicTasksForCurrentVisibility() {
        if self.isPanelPresented {
            if self.mediumFrequencyTask == nil {
                self.mediumFrequencyTask = self.startPeriodicTask(intervalProvider: { state in
                    state.mediumFrequencyIntervalNanoseconds
                }, operation: { state in
                    await state.refreshMediumFrequency()
                })
            }

            if self.lowFrequencyTask == nil {
                self.lowFrequencyTask = self.startPeriodicTask(intervalProvider: { state in
                    state.lowFrequencyIntervalNanoseconds
                }, operation: { state in
                    await state.refreshLowFrequency()
                })
            }
            return
        }

        self.mediumFrequencyTask?.cancel()
        self.lowFrequencyTask?.cancel()
        self.mediumFrequencyTask = nil
        self.lowFrequencyTask = nil
    }

    func refreshFromAPI(includeSlowCalls: Bool) async {
        await self.refreshHighFrequency()
        await self.refreshMediumFrequency(force: true)
        if includeSlowCalls {
            await self.refreshLowFrequency(force: true)
        }
    }

    private func refreshHighFrequency() async {
        self.updateDataAcquisitionPolicy()
    }

    func setPanelVisibility(_ presented: Bool) {
        guard self.isPanelPresented != presented else { return }
        self.isPanelPresented = presented
        if !presented {
            self.cancelProxyPortsAutoSave()
            self.clearTrafficPresentationHistory()
            self.releasePanelCachedData()
        }
        self.trimInMemoryLogsForCurrentVisibility()
        self.updateDataAcquisitionPolicy()

        guard presented else { return }
        self.flushPendingTrafficSnapshotIfNeeded(immediately: true)
        self.scheduleRefreshForActivatedTab(self.activeMenuTab)
    }

    func setActiveMenuTab(_ tab: RootTab) {
        let changed = self.activeMenuTab != tab
        self.activeMenuTab = tab
        self.updateDataAcquisitionPolicy()

        guard changed else { return }
        self.scheduleRefreshForActivatedTab(tab)
    }

    private func scheduleRefreshForActivatedTab(_ tab: RootTab) {
        self.activatedTabRefreshGeneration += 1
        let generation = self.activatedTabRefreshGeneration
        Task { [weak self] in
            guard let self else { return }
            await self.refreshForActivatedTab(tab, generation: generation)
        }
    }

    func desiredDataAcquisitionPolicy(
        panelPresented: Bool,
        activeTab: RootTab) -> DataAcquisitionPolicy
    {
        let trafficEnabled = panelPresented || self.statusBarDisplayMode != .iconOnly

        if !panelPresented {
            return DataAcquisitionPolicy(
                enableTrafficStream: trafficEnabled,
                enableMemoryStream: false,
                enableConnectionsStream: false,
                connectionsIntervalMilliseconds: nil,
                enableLogsStream: false,
                mediumFrequencyIntervalNanoseconds: self.backgroundMediumFrequencyIntervalNanoseconds,
                lowFrequencyIntervalNanoseconds: self.foregroundLowFrequencyOtherTabsIntervalNanoseconds)
        }

        let lowFrequencyInterval: UInt64 = switch activeTab {
        case .proxy, .rules:
            self.foregroundLowFrequencyPrimaryTabsIntervalNanoseconds
        default:
            self.foregroundLowFrequencyOtherTabsIntervalNanoseconds
        }

        let memoryEnabled = activeTab == .proxy
        let connectionsEnabled = activeTab == .proxy || activeTab == .activity
        let logsEnabled = activeTab == .logs

        return DataAcquisitionPolicy(
            enableTrafficStream: trafficEnabled,
            enableMemoryStream: memoryEnabled,
            enableConnectionsStream: connectionsEnabled,
            connectionsIntervalMilliseconds: connectionsEnabled ? 1000 : nil,
            enableLogsStream: logsEnabled,
            mediumFrequencyIntervalNanoseconds: self.foregroundMediumFrequencyIntervalNanoseconds,
            lowFrequencyIntervalNanoseconds: lowFrequencyInterval)
    }

    func updateDataAcquisitionPolicy() {
        guard self.isRemoteSessionActive else {
            self.teardownStreams()
            self.mediumFrequencyIntervalNanoseconds = self.foregroundMediumFrequencyIntervalNanoseconds
            self.lowFrequencyIntervalNanoseconds = self.foregroundLowFrequencyPrimaryTabsIntervalNanoseconds
            return
        }

        let policy = self.desiredDataAcquisitionPolicy(
            panelPresented: self.isPanelPresented,
            activeTab: self.activeMenuTab)

        self.mediumFrequencyIntervalNanoseconds = policy.mediumFrequencyIntervalNanoseconds
        self.lowFrequencyIntervalNanoseconds = policy.lowFrequencyIntervalNanoseconds
        self.ensurePeriodicTasksForCurrentVisibility()
        self.applyStreamPolicy(policy)
    }

    func refreshForActivatedTab(_ tab: RootTab, generation: Int? = nil) async {
        guard self.isRemoteSessionActive else { return }

        func shouldContinueRefresh() -> Bool {
            guard let generation else { return true }
            return generation == self.activatedTabRefreshGeneration
        }

        guard shouldContinueRefresh() else { return }

        switch tab {
        case .proxy:
            await self.refreshMediumFrequency(force: true)
            guard shouldContinueRefresh() else { return }
            if self.proxyProvidersDetail.isEmpty || self.ruleItems.isEmpty {
                await self.refreshProvidersAndRules()
            }
        case .rules:
            await self.refreshProvidersAndRules()
        case .activity:
            await self.refreshConnections()
        case .logs:
            break
        case .system:
            await self.refreshMediumFrequency(force: true)
        }
    }

    private func refreshMediumFrequency(force: Bool = false) async {
        guard force || self.isPanelPresented else { return }

        await self.runRefresh {
            let client = try self.clientOrThrow()
            if self.activeMenuTab == .proxy {
                async let versionTask: VersionInfo = client.request(.version)
                async let configTask: ConfigSnapshot = client.request(.getConfigs)
                async let proxyGroupsTask = self.fetchProxyGroupsAndProviders(using: client)

                let (version, config, proxyGroupsPayload) = try await (versionTask, configTask, proxyGroupsTask)
                self.version = version.version
                self.applyRuntimeConfigSnapshot(config)
                self.applyProxyGroupsResponse(
                    proxyGroupsPayload.groups,
                    proxyProviders: proxyGroupsPayload.providers)
            } else {
                async let versionTask: VersionInfo = client.request(.version)
                async let configTask: ConfigSnapshot = client.request(.getConfigs)

                let (version, config) = try await (versionTask, configTask)
                self.version = version.version
                self.applyRuntimeConfigSnapshot(config)
            }
        }
    }

    func fetchRuntimeConfigSnapshot() async throws -> ConfigSnapshot {
        let client = try self.clientOrThrow()
        let config: ConfigSnapshot = try await client.request(.getConfigs)
        self.applyRuntimeConfigSnapshot(config)
        return config
    }

    private func applyRuntimeConfigSnapshot(_ config: ConfigSnapshot) {
        if let remoteMode = self.normalizeMode(config.mode) {
            self.currentMode = remoteMode
        }
        self.logLevel = config.logLevel ?? self.logLevel
        self.port = config.port
        self.socksPort = config.socksPort
        self.redirPort = config.redirPort
        self.tproxyPort = config.tproxyPort
        self.mixedPort = config.mixedPort ?? 0
        self.syncEditableSettings(from: config)
    }

    func resetTrafficPresentation() {
        self.traffic = TrafficSnapshot(up: 0, down: 0)
        self.clearTrafficPresentationHistory()
    }

    func clearTrafficPresentationHistory() {
        self.displayUpTotal = 0
        self.displayDownTotal = 0
        self.trafficHistoryUp = []
        self.trafficHistoryDown = []
        self.lastTrafficSampleAt = nil
    }

    func releasePanelCachedData() {
        self.connectionsCount = 0
        self.connections.removeAll(keepingCapacity: false)

        self.memory = MemorySnapshot(inuse: 0)

        self.proxyGroups.removeAll(keepingCapacity: false)
        self.groupLatencyLoading.removeAll(keepingCapacity: false)
        self.groupLatencies.removeAll(keepingCapacity: false)
        self.proxyHistoryLatestDelay.removeAll(keepingCapacity: false)

        self.providerProxyCount = 0
        self.providerRuleCount = 0
        self.rulesCount = 0
        self.proxyProvidersDetail.removeAll(keepingCapacity: false)
        self.expandedProxyProviders.removeAll(keepingCapacity: false)
        self.providerNodeLatencies.removeAll(keepingCapacity: false)
        self.providerNodeTesting.removeAll(keepingCapacity: false)
        self.providerBatchTesting.removeAll(keepingCapacity: false)
        self.providerUpdating.removeAll(keepingCapacity: false)
        self.ruleProviderUpdating.removeAll(keepingCapacity: false)
        self.ruleProviders.removeAll(keepingCapacity: false)
        self.ruleItems.removeAll(keepingCapacity: false)
    }

    func appendTrafficHistory(up: Int64, down: Int64) {
        self.trafficHistoryUp.append(max(0, up))
        self.trafficHistoryDown.append(max(0, down))

        if self.trafficHistoryUp.count > self.historyMaxPoints {
            self.trafficHistoryUp.removeFirst(self.trafficHistoryUp.count - self.historyMaxPoints)
        }
        if self.trafficHistoryDown.count > self.historyMaxPoints {
            self.trafficHistoryDown.removeFirst(self.trafficHistoryDown.count - self.historyMaxPoints)
        }
    }

    func updateTrafficTotals(from snapshot: TrafficSnapshot) {
        if let upTotal = snapshot.upTotal, let downTotal = snapshot.downTotal {
            self.displayUpTotal = max(0, upTotal)
            self.displayDownTotal = max(0, downTotal)
            self.lastTrafficSampleAt = Date()
            return
        }

        let now = Date()
        if let last = self.lastTrafficSampleAt {
            let delta = max(0, now.timeIntervalSince(last))
            self.displayUpTotal += Int64(Double(max(0, snapshot.up)) * delta)
            self.displayDownTotal += Int64(Double(max(0, snapshot.down)) * delta)
        }
        self.lastTrafficSampleAt = now
    }

    private func refreshLowFrequency(force: Bool = false) async {
        guard force || self.isPanelPresented else { return }
        switch self.activeMenuTab {
        case .proxy, .rules:
            await self.refreshProvidersAndRules()
        case .system:
            await self.refreshMediumFrequency(force: true)
        case .activity, .logs:
            break
        }
    }

    func refreshProxyGroups() async {
        await self.runRefresh {
            let client = try self.clientOrThrow()
            let payload = try await self.fetchProxyGroupsAndProviders(using: client)
            self.applyProxyGroupsResponse(payload.groups, proxyProviders: payload.providers)
        }
    }

    private func fetchProxyGroupsAndProviders(using client: MihomoAPIClient) async throws -> (
        groups: ProxyGroupsResponse,
        providers: [String: ProviderDetail])
    {
        async let groupsTask: ProxyGroupsResponse = client.request(.proxies)
        async let proxyProvidersTask: ProviderSummary? = try? await client.request(.proxyProviders)
        let (groupsResponse, proxyProviders) = try await (groupsTask, proxyProvidersTask)
        return (groupsResponse, proxyProviders?.providers ?? [:])
    }

    private func applyProxyGroupsResponse(
        _ response: ProxyGroupsResponse,
        proxyProviders: [String: ProviderDetail] = [:])
    {
        let providerLookup = proxyProviders.isEmpty ? self.proxyProvidersDetail : proxyProviders
        let proxiesWithHealthcheckConfig = response.proxies.values.map { proxy in
            let provider = providerLookup[proxy.name]
            let resolvedTestURL = self.normalizedHealthcheckURL(proxy.testUrl)
                ?? self.normalizedHealthcheckURL(provider?.testUrl)
            let resolvedTimeout = self.normalizedHealthcheckTimeout(proxy.timeout)
                ?? self.normalizedHealthcheckTimeout(provider?.timeout)

            return ProxyGroup(
                name: proxy.name,
                type: proxy.type,
                now: proxy.now,
                all: proxy.all,
                testUrl: resolvedTestURL,
                timeout: resolvedTimeout,
                icon: proxy.icon,
                hidden: proxy.hidden,
                latestDelay: proxy.latestDelay)
        }

        let sortIndex = (response.proxies["GLOBAL"]?.all ?? []) + ["GLOBAL"]
        var sortIndexMap: [String: Int] = [:]
        for (index, name) in sortIndex.enumerated() where sortIndexMap[name] == nil {
            sortIndexMap[name] = index
        }

        self.proxyGroups = proxiesWithHealthcheckConfig
            .enumerated()
            .filter { !$0.element.all.isEmpty }
            .sorted { lhs, rhs in
                let lhsOrder = sortIndexMap[lhs.element.name] ?? -1
                let rhsOrder = sortIndexMap[rhs.element.name] ?? -1

                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)

        var historyMap: [String: Int] = [:]
        for proxy in response.proxies.values {
            if let latest = proxy.latestDelay {
                historyMap[proxy.name] = latest
            }
        }
        self.proxyHistoryLatestDelay = historyMap
    }

    func normalizedHealthcheckURL(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    func normalizedHealthcheckTimeout(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    func refreshConnections() async {
        let policy = self.desiredDataAcquisitionPolicy(panelPresented: self.isPanelPresented, activeTab: self.activeMenuTab)
        guard policy.enableConnectionsStream else {
            self.cancelStream(.connections)
            return
        }
        self.startConnectionsStream(intervalMilliseconds: policy.connectionsIntervalMilliseconds)
    }

    private func applyStreamPolicy(_ policy: DataAcquisitionPolicy) {
        self.syncStream(.traffic, enabled: policy.enableTrafficStream) { self.startTrafficStream() }
        self.syncStream(.memory, enabled: policy.enableMemoryStream) { self.startMemoryStream() }
        self.syncConnectionsStream(
            enabled: policy.enableConnectionsStream,
            intervalMilliseconds: policy.connectionsIntervalMilliseconds)
        self.syncStream(.logs, enabled: policy.enableLogsStream) { self.startLogsStream() }
    }

    private func syncConnectionsStream(enabled: Bool, intervalMilliseconds: Int?) {
        self.syncStream(
            .connections,
            enabled: enabled,
            forceRestart: self.currentConnectionsStreamIntervalMilliseconds != intervalMilliseconds)
        {
            self.startConnectionsStream(intervalMilliseconds: intervalMilliseconds)
        }
    }

    private func syncStream(
        _ kind: StreamKind,
        enabled: Bool,
        forceRestart: Bool = false,
        start: () -> Void)
    {
        guard enabled else {
            self.cancelStream(kind)
            return
        }
        guard forceRestart || self.webSocketTask(for: kind) == nil else { return }
        start()
    }
}
