import Foundation

enum RemoteConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed
}

enum RuntimeVisualStatus {
    case stopped
    case starting
    case runningHealthy
    case runningDegraded
    case failed
}

enum StartTrigger {
    case manual
}

enum StopTrigger {
    case manual
}

enum CoreActionState {
    case idle
    case starting
    case stopping
    case restarting
}

enum ConfigLogLevel: String, CaseIterable {
    case silent
    case error
    case warning
    case info
    case debug
}

enum ConfigPatchValue: Sendable {
    case bool(Bool)
    case int(Int)
    case string(String)
    indirect case object([String: ConfigPatchValue])

    var jsonValue: JSONValue {
        switch self {
        case let .bool(value):
            .bool(value)
        case let .int(value):
            .int(value)
        case let .string(value):
            .string(value)
        case let .object(value):
            .object(value.mapValues(\.jsonValue))
        }
    }
}

enum StatusBarDisplayMode: String, CaseIterable, Identifiable {
    case iconOnly = "icon_only"
    case iconAndSpeed = "icon_and_speed"
    case speedOnly = "speed_only"

    var id: String {
        rawValue
    }
}

enum TrafficIndicatorUnit: String, CaseIterable, Identifiable {
    case byte
    case bit

    var id: String {
        rawValue
    }
}

enum ProxyGroupFontSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String {
        rawValue
    }
}

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String {
        rawValue
    }
}

struct DataAcquisitionPolicy: Equatable {
    let enableTrafficStream: Bool
    let enableMemoryStream: Bool
    let enableConnectionsStream: Bool
    let connectionsIntervalMilliseconds: Int?
    let enableLogsStream: Bool
    let mediumFrequencyIntervalNanoseconds: UInt64
    let lowFrequencyIntervalNanoseconds: UInt64
}

enum ProviderRefreshTrigger {
    case start
    case restart
    case configSwitch
}

enum ProviderRefreshPhase {
    case idle
    case updating
    case succeeded
    case failed
    case cancelled
}

struct ProviderRefreshStatus {
    let phase: ProviderRefreshPhase
    let trigger: ProviderRefreshTrigger?
    let progressDone: Int
    let progressTotal: Int
    let message: String?
    let updatedAt: Date?

    static let idle = ProviderRefreshStatus(
        phase: .idle,
        trigger: nil,
        progressDone: 0,
        progressTotal: 0,
        message: nil,
        updatedAt: nil)
}

struct ProviderNodeKey: Hashable {
    let provider: String
    let node: String
}

struct MenuBarSpeedLines: Equatable {
    let up: String
    let down: String

    static let zero = MenuBarSpeedLines(up: "↑0K", down: "↓0K")
}

struct MenuBarDisplay: Equatable {
    let mode: StatusBarDisplayMode
    let symbolName: String?
    let speedLines: MenuBarSpeedLines?
}

struct OpenWrtTrafficSettingsSnapshot: Equatable, Codable {
    let enabled: Bool
    let endpoint: String
    let interfaceName: String
    let username: String
    let password: String
}

struct EditableSettingsSnapshot: Equatable, Codable {
    let allowLan: Bool
    let ipv6: Bool
    let tcpConcurrent: Bool
    let tunEnabled: Bool
    let logLevel: String
    let port: String
    let socksPort: String
    let mixedPort: String
    let redirPort: String
    let tproxyPort: String

    init(config: ConfigSnapshot) {
        self.allowLan = config.allowLan ?? false
        self.ipv6 = config.ipv6 ?? false
        self.tcpConcurrent = config.tcpConcurrent ?? false
        self.tunEnabled = config.tunEnabled ?? false
        self.logLevel = ConfigLogLevel(rawValue: config.logLevel ?? "")?.rawValue ?? ConfigLogLevel.info.rawValue
        self.port = config.port.map(String.init) ?? ""
        self.socksPort = config.socksPort.map(String.init) ?? ""
        self.mixedPort = config.mixedPort.map(String.init) ?? ""
        self.redirPort = config.redirPort.map(String.init) ?? ""
        self.tproxyPort = config.tproxyPort.map(String.init) ?? ""
    }

    init(
        allowLan: Bool,
        ipv6: Bool,
        tcpConcurrent: Bool,
        tunEnabled: Bool,
        logLevel: String,
        port: String,
        socksPort: String,
        mixedPort: String,
        redirPort: String,
        tproxyPort: String)
    {
        self.allowLan = allowLan
        self.ipv6 = ipv6
        self.tcpConcurrent = tcpConcurrent
        self.tunEnabled = tunEnabled
        self.logLevel = logLevel
        self.port = port
        self.socksPort = socksPort
        self.mixedPort = mixedPort
        self.redirPort = redirPort
        self.tproxyPort = tproxyPort
    }
}
