import AppKit
import Foundation
import SwiftUI

@MainActor
final class RemoteAppState: ObservableObject {
    @Published var statusText: String = "Disconnected" {
        didSet { self.refreshMenuBarDisplaySnapshotIfNeeded() }
    }

    @Published var connectionState: RemoteConnectionState = .disconnected {
        didSet { self.refreshMenuBarDisplaySnapshotIfNeeded() }
    }

    @Published var version: String = "-"
    @Published var controller: String = "http://127.0.0.1:9090"
    @Published var externalControllerDisplay: String = "http://127.0.0.1:9090"
    @Published var controllerUIURL: String = "http://127.0.0.1:9090/ui"
    @Published var controllerSecret: String?
    @Published var controllerInput: String = "http://127.0.0.1:9090"
    @Published var controllerSecretInput: String = ""
    @Published var menuBarShowsOpenWrtTraffic: Bool = false {
        didSet {
            self.persistOpenWrtTrafficSettings()
            self.updateOpenWrtTrafficPolling()
            self.refreshMenuBarDisplaySnapshotIfNeeded()
        }
    }
    @Published var openWrtEndpointInput: String = "" {
        didSet { self.persistOpenWrtTrafficSettings() }
    }
    @Published var openWrtInterfaceInput: String = "" {
        didSet { self.persistOpenWrtTrafficSettings() }
    }
    @Published var openWrtUsernameInput: String = "" {
        didSet { self.persistOpenWrtTrafficSettings() }
    }
    @Published var openWrtPasswordInput: String = "" {
        didSet { self.persistOpenWrtTrafficSettings() }
    }
    @Published var trafficIndicatorUnit: TrafficIndicatorUnit = .byte {
        didSet {
            self.persistTrafficIndicatorUnit()
            self.refreshMenuBarDisplaySnapshotIfNeeded()
        }
    }
    @Published var proxyGroupFontSize: ProxyGroupFontSize = .medium {
        didSet { self.persistProxyGroupFontSize() }
    }

    @Published var traffic = TrafficSnapshot(up: 0, down: 0) {
        didSet { self.refreshMenuBarDisplaySnapshotIfNeeded() }
    }

    @Published var openWrtTraffic = TrafficSnapshot(up: 0, down: 0) {
        didSet { self.refreshMenuBarDisplaySnapshotIfNeeded() }
    }

    @Published var memory = MemorySnapshot(inuse: 0)
    @Published var displayUpTotal: Int64 = 0
    @Published var displayDownTotal: Int64 = 0
    @Published var trafficHistoryUp: [Int64] = []
    @Published var trafficHistoryDown: [Int64] = []

    @Published var connectionsCount: Int = 0
    @Published var connections: [ConnectionSummary] = []

    @Published var currentMode: CoreMode = .rule
    @Published var logLevel: String = ConfigLogLevel.info.rawValue
    @Published var port: Int?
    @Published var socksPort: Int?
    @Published var redirPort: Int?
    @Published var tproxyPort: Int?
    @Published var mixedPort: Int = 0

    @Published var proxyGroups: [ProxyGroup] = []
    @Published var groupLatencyLoading: Set<String> = []
    @Published var groupLatencies: [String: [String: Int]] = [:]
    @Published var proxyHistoryLatestDelay: [String: Int] = [:]

    @Published var providerProxyCount: Int = 0
    @Published var providerRuleCount: Int = 0
    @Published var rulesCount: Int = 0
    @Published var proxyProvidersDetail: [String: ProviderDetail] = [:]
    @Published var expandedProxyProviders: Set<String> = []
    @Published var providerNodeLatencies: [String: [String: Int]] = [:]
    @Published var providerNodeTesting: Set<ProviderNodeKey> = []
    @Published var providerBatchTesting: Set<String> = []
    @Published var providerUpdating: Set<String> = []
    @Published var ruleProviderUpdating: Set<String> = []
    @Published var ruleProviders: [String: ProviderDetail] = [:]
    @Published var ruleItems: [RuleItem] = []
    @Published var isRuleProvidersRefreshing: Bool = false

    @Published var apiStatus: APIHealth = .unknown {
        didSet { self.refreshMenuBarDisplaySnapshotIfNeeded() }
    }

    @Published var errorLogs: [AppErrorLogEntry] = []
    @Published var coreActionState: CoreActionState = .idle
    @Published var providerRefreshStatus: ProviderRefreshStatus = .idle
    @Published var uiLanguage: AppLanguage = .zhHans
    @Published var appearanceMode: AppAppearanceMode = .system
    @Published var isPanelPresented: Bool = false
    @Published var activeMenuTab: RootTab = .proxy
    @Published private(set) var menuBarDisplaySnapshot = MenuBarDisplay(
        mode: .iconOnly,
        symbolName: "link.circle",
        speedLines: nil)

    @Published var settingsAllowLan: Bool = false {
        didSet { self.persistEditableSettingsSnapshot() }
    }

    @Published var settingsIPv6: Bool = false {
        didSet { self.persistEditableSettingsSnapshot() }
    }

    @Published var settingsTCPConcurrent: Bool = false {
        didSet { self.persistEditableSettingsSnapshot() }
    }

    @Published var settingsTunEnabled: Bool = false {
        didSet { self.persistEditableSettingsSnapshot() }
    }

    @Published var settingsLogLevel: String = ConfigLogLevel.info.rawValue {
        didSet { self.persistEditableSettingsSnapshot() }
    }

    @Published var settingsPort: String = "" {
        didSet { self.persistEditableSettingsSnapshot() }
    }

    @Published var settingsSocksPort: String = "" {
        didSet { self.persistEditableSettingsSnapshot() }
    }

    @Published var settingsMixedPort: String = "" {
        didSet { self.persistEditableSettingsSnapshot() }
    }

    @Published var settingsRedirPort: String = "" {
        didSet { self.persistEditableSettingsSnapshot() }
    }

    @Published var settingsTProxyPort: String = "" {
        didSet { self.persistEditableSettingsSnapshot() }
    }

    @Published var settingsSyncingKey: String?
    @Published var settingsErrorMessage: String?
    @Published var settingsSavedMessage: String?

    var lastSyncedEditableSettings: EditableSettingsSnapshot?
    var suppressSettingsPersistence = false

    var runtimeVisualStatus: RuntimeVisualStatus {
        switch self.connectionState {
        case .disconnected:
            .stopped
        case .connecting:
            .starting
        case .failed:
            .failed
        case .connected:
            switch self.apiStatus {
            case .healthy:
                .runningHealthy
            case .unknown, .degraded:
                .runningDegraded
            case .failed:
                .failed
            }
        }
    }

    var runtimeStatusText: String {
        switch self.runtimeVisualStatus {
        case .starting: tr("app.runtime.starting")
        case .runningHealthy, .runningDegraded: tr("app.runtime.running")
        case .failed: tr("app.runtime.failed")
        case .stopped: tr("app.runtime.stopped")
        }
    }

    var isExternalControllerWildcardIPv4: Bool {
        guard let host = self.controllerHost(from: self.externalControllerDisplay) else {
            return false
        }
        return host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "0.0.0.0"
    }

    var isRuntimeRunning: Bool {
        self.connectionState == .connected
    }

    var isRemoteSessionActive: Bool {
        self.connectionState == .connected || self.connectionState == .connecting
    }

    var menuBarSymbolName: String {
        switch self.runtimeVisualStatus {
        case .runningHealthy:
            "antenna.radiowaves.left.and.right.circle.fill"
        case .runningDegraded:
            "antenna.radiowaves.left.and.right.circle"
        case .starting:
            "arrow.trianglehead.2.clockwise"
        case .failed:
            "exclamationmark.triangle.fill"
        case .stopped:
            "link.circle"
        }
    }

    var statusBarDisplayMode: StatusBarDisplayMode {
        get { StatusBarDisplayMode(rawValue: self.statusBarDisplayModeRaw) ?? .iconOnly }
        set {
            guard self.statusBarDisplayModeRaw != newValue.rawValue else { return }
            self.statusBarDisplayModeRaw = newValue.rawValue
            self.refreshMenuBarDisplaySnapshotIfNeeded()
            self.updateOpenWrtTrafficPolling()
            self.updateDataAcquisitionPolicy()
            if newValue != .iconOnly {
                self.flushPendingTrafficSnapshotIfNeeded(immediately: true)
            }
        }
    }

    var menuBarSpeedLines: MenuBarSpeedLines {
        let source = self.menuBarTrafficSnapshot
        let up = self.compactMenuBarRate(max(0, source.up))
        let down = self.compactMenuBarRate(max(0, source.down))
        return MenuBarSpeedLines(up: "\(up)↑", down: "\(down)↓")
    }

    var menuBarDisplay: MenuBarDisplay {
        self.menuBarDisplaySnapshot
    }

    private var computedMenuBarDisplay: MenuBarDisplay {
        switch self.statusBarDisplayMode {
        case .iconOnly:
            MenuBarDisplay(mode: .iconOnly, symbolName: self.menuBarSymbolName, speedLines: nil)
        case .iconAndSpeed:
            MenuBarDisplay(mode: .iconAndSpeed, symbolName: self.menuBarSymbolName, speedLines: self.menuBarSpeedLines)
        case .speedOnly:
            MenuBarDisplay(mode: .speedOnly, symbolName: nil, speedLines: self.menuBarSpeedLines)
        }
    }

    func compactMenuBarRate(_ bytesPerSecond: Int64) -> String {
        ValueFormatter.compactTrafficRateNoSpace(bytesPerSecond: bytesPerSecond, unit: self.trafficIndicatorUnit)
    }

    func refreshMenuBarDisplaySnapshotIfNeeded() {
        let next = self.computedMenuBarDisplay
        guard next != self.menuBarDisplaySnapshot else { return }
        self.menuBarDisplaySnapshot = next
    }

    var isModeSwitchEnabled: Bool {
        self.isRuntimeRunning && self.apiStatus == .healthy
    }

    var isCoreActionProcessing: Bool {
        self.coreActionState != .idle
    }

    var isPrimaryCoreActionEnabled: Bool {
        !self.isCoreActionProcessing && self.isControllerConfigured
    }

    var primaryCoreActionLabel: String {
        if self.isCoreActionProcessing {
            return tr("app.primary.processing")
        }
        return tr("ui.action.reconnect")
    }

    var primaryCoreActionIconName: String {
        self.isCoreActionProcessing ? "hourglass" : "arrow.clockwise"
    }

    var isControllerConfigured: Bool {
        self.validatedControllerAddress(self.controller) != nil
    }

    var apiClient: MihomoAPIClient?
    var modeSwitchTransportOverride: MihomoAPITransporting?
    var settingsPatchTransportOverride: MihomoAPITransporting?
    let openWrtTrafficService = OpenWrtTrafficService()

    var mediumFrequencyTask: Task<Void, Never>?
    var lowFrequencyTask: Task<Void, Never>?
    var openWrtTrafficPollTask: Task<Void, Never>?
    var streamReceiveTasks: [StreamKind: Task<Void, Never>] = [:]
    var streamWebSocketTasks: [StreamKind: URLSessionWebSocketTask] = [:]
    var streamReconnectAttempts: [String: Int] = [:]
    var streamLastDisconnectLogAt: [String: Date] = [:]
    var streamLastDisconnectLogMessage: [String: String] = [:]
    var proxyPortsAutoSaveTask: Task<Void, Never>?
    var settingsFeedbackClearTask: Task<Void, Never>?
    var providerRefreshTask: Task<Void, Never>?
    var trafficDecodeTask: Task<Void, Never>?
    var trafficWatchdogTask: Task<Void, Never>?
    var mihomoLogFlushTask: Task<Void, Never>?
    var providerRefreshGeneration: Int = 0
    var lastTrafficSampleAt: Date?
    var lastTrafficDecodeAt: Date = .distantPast
    var lastTrafficPayloadReceivedAt: Date?
    var pendingTrafficPayload: Data?
    var pendingMihomoLogs: [AppErrorLogEntry] = []
    var modeSwitchInFlight = false
    var activatedTabRefreshGeneration: Int = 0

    let defaults = UserDefaults.standard
    @AppStorage("clashbar.statusbar.display.mode") private var statusBarDisplayModeRaw: String = StatusBarDisplayMode
        .iconOnly.rawValue
    @AppStorage("clashbar.proxy.node.hide_unavailable") var hideUnavailableProxyNodes: Bool = false
    let controllerAddressKey = "clashbar.remote.controller.address.v1"
    let controllerSecretKey = "clashbar.remote.controller.secret.v1"
    let openWrtTrafficSettingsKey = "clashbar.openwrt.traffic.settings.v1"
    let editableSettingsSnapshotKey = "clashbar.settings.remote.editable.snapshot.v1"
    let trafficIndicatorUnitKey = "clashbar.traffic.indicator.unit.v1"
    let proxyGroupFontSizeKey = "clashbar.proxy.group.font.size.v1"
    let uiLanguageKey = "clashbar.ui.language"
    let appearanceModeKey = "clashbar.ui.appearance.mode"
    let maxLogEntries = 200
    let hiddenPanelMaxInMemoryLogEntries = 20
    let maxBufferedMihomoLogEntries = 40
    let maxRetainedConnections = 300
    let historyMaxPoints = 60
    let mihomoLogFlushIntervalNanoseconds: UInt64 = 150_000_000
    let foregroundMediumFrequencyIntervalNanoseconds: UInt64 = 4_000_000_000
    let backgroundMediumFrequencyIntervalNanoseconds: UInt64 = 12_000_000_000
    let foregroundLowFrequencyPrimaryTabsIntervalNanoseconds: UInt64 = 20_000_000_000
    let foregroundLowFrequencyOtherTabsIntervalNanoseconds: UInt64 = 45_000_000_000
    let trafficPublishIntervalNanoseconds: UInt64 = 500_000_000
    let trafficWatchdogIntervalNanoseconds: UInt64 = 2_000_000_000
    let trafficStallTimeout: TimeInterval = 6
    let openWrtTrafficPollIntervalNanoseconds: UInt64 = 1_000_000_000
    let streamDisconnectLogThrottleInterval: TimeInterval = 2
    let streamReconnectBaseDelayNanoseconds: UInt64 = 1_000_000_000
    let streamReconnectMaxDelayNanoseconds: UInt64 = 8_000_000_000
    let defaultHealthcheckURL = "https://www.gstatic.com/generate_204"
    let defaultHealthcheckTimeoutMilliseconds = 5000
    let openWrtTrafficErrorLogThrottleInterval: TimeInterval = 30
    var mediumFrequencyIntervalNanoseconds: UInt64 = 4_000_000_000
    var lowFrequencyIntervalNanoseconds: UInt64 = 20_000_000_000
    var currentConnectionsStreamIntervalMilliseconds: Int?
    var clashbarLogFileURL: URL?
    var mihomoLogFileURL: URL?
    var clashbarLogStore: AppLogStore?
    var mihomoLogStore: AppLogStore?
    var externalControllerWarningKeys: Set<String> = []
    var lastOpenWrtTrafficErrorMessage: String?
    var lastOpenWrtTrafficErrorAt: Date?
    let streamJSONDecoder = JSONDecoder()

    var usesOpenWrtMenuBarTraffic: Bool {
        self.menuBarShowsOpenWrtTraffic
    }

    var menuBarTrafficSnapshot: TrafficSnapshot {
        self.usesOpenWrtMenuBarTraffic ? self.openWrtTraffic : self.traffic
    }

    init(
        clashbarLogStore: AppLogStore? = nil,
        mihomoLogStore: AppLogStore? = nil,
        startBackgroundRefresh: Bool = true)
    {
        self.clashbarLogStore = clashbarLogStore
        self.mihomoLogStore = mihomoLogStore
        self.uiLanguage = self.loadPersistedUILanguage()
        self.appearanceMode = self.loadPersistedAppearanceMode()
        self.trafficIndicatorUnit = self.loadPersistedTrafficIndicatorUnit()
        self.proxyGroupFontSize = self.loadPersistedProxyGroupFontSize()
        self.controller = self.loadPersistedControllerAddress()
        self.externalControllerDisplay = self.controller
        self.controllerUIURL = self.makeControllerUIURL(self.controller)
        self.controllerSecret = self.loadPersistedControllerSecret()
        self.controllerInput = self.controller
        self.controllerSecretInput = self.controllerSecret ?? ""
        self.applyOpenWrtTrafficSettingsSnapshot(self.loadPersistedOpenWrtTrafficSettings())
        self.applyAppAppearance()

        do {
            try self.bootstrapSupportDirectories()
            if let clashbarLogFileURL, self.clashbarLogStore == nil {
                self.clashbarLogStore = AppLogStore(logFileURL: clashbarLogFileURL)
            }
            if let mihomoLogFileURL, self.mihomoLogStore == nil {
                self.mihomoLogStore = AppLogStore(logFileURL: mihomoLogFileURL)
            }
            self.ensureLogFileExists()
        } catch {
            self.appendLog(level: "error", message: "Failed to initialize app directories: \(error.localizedDescription)")
        }

        if let persisted = self.loadPersistedEditableSettingsSnapshot() {
            self.applyEditableSettingsSnapshotToUI(persisted)
            self.lastSyncedEditableSettings = persisted
        }

        self.ensureAPIClient()
        self.updateOpenWrtTrafficPolling()
        self.refreshMenuBarDisplaySnapshotIfNeeded()

        if startBackgroundRefresh, self.isControllerConfigured {
            Task { [weak self] in
                await self?.connectRemoteController()
            }
        }
    }

    deinit {
        self.trafficDecodeTask?.cancel()
        self.trafficWatchdogTask?.cancel()
        self.mihomoLogFlushTask?.cancel()
        self.mediumFrequencyTask?.cancel()
        self.lowFrequencyTask?.cancel()
        self.openWrtTrafficPollTask?.cancel()
        self.providerRefreshTask?.cancel()
        self.proxyPortsAutoSaveTask?.cancel()
        self.settingsFeedbackClearTask?.cancel()
        for task in self.streamReceiveTasks.values {
            task.cancel()
        }
        for webSocketTask in self.streamWebSocketTasks.values {
            webSocketTask.cancel(with: .goingAway, reason: nil)
        }
    }

    private var appSupportRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/clashbar", isDirectory: true)
    }

    private var logsDirectoryURL: URL {
        self.appSupportRootURL.appendingPathComponent("logs", isDirectory: true)
    }

    private func bootstrapSupportDirectories() throws {
        try FileManager.default.createDirectory(at: self.appSupportRootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.logsDirectoryURL, withIntermediateDirectories: true)
        self.clashbarLogFileURL = self.logsDirectoryURL.appendingPathComponent("clashbar.log", isDirectory: false)
        self.mihomoLogFileURL = self.logsDirectoryURL.appendingPathComponent("mihomo.log", isDirectory: false)
    }
}

typealias AppState = RemoteAppState
