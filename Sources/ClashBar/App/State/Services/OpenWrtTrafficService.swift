import Foundation

struct OpenWrtTrafficConfiguration: Equatable, Sendable {
    let endpoint: String
    let interfaceName: String
    let username: String
    let password: String
}

enum OpenWrtTrafficServiceError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case httpStatus(Int, String)
    case permissionDenied(String)
    case rpcError(String)
    case missingSessionID
    case missingStatistics

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "OpenWrt endpoint is invalid"
        case .invalidResponse:
            "OpenWrt returned an invalid response"
        case let .httpStatus(code, message):
            "OpenWrt request failed (\(code)): \(message)"
        case let .permissionDenied(message):
            "OpenWrt RPC failed: \(message)"
        case let .rpcError(message):
            "OpenWrt RPC failed: \(message)"
        case .missingSessionID:
            "OpenWrt login did not return a session id"
        case .missingStatistics:
            "OpenWrt interface statistics are missing"
        }
    }

    var shouldRefreshSession: Bool {
        switch self {
        case .permissionDenied:
            true
        default:
            false
        }
    }
}

actor OpenWrtTrafficService {
    private struct SessionState {
        let id: String
    }

    private struct InterfaceCounters {
        let rxBytes: Int64
        let txBytes: Int64
        let sampledAt: Date
    }

    private let session: URLSession
    private var sessionState: SessionState?
    private var lastCounters: InterfaceCounters?
    private var lastConfigurationFingerprint: String?

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 3
            config.timeoutIntervalForResource = 5
            config.waitsForConnectivity = false
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.urlCache = nil
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil
            self.session = URLSession(configuration: config)
        }
    }

    func reset() {
        self.sessionState = nil
        self.lastCounters = nil
        self.lastConfigurationFingerprint = nil
    }

    func pollTraffic(configuration: OpenWrtTrafficConfiguration) async throws -> TrafficSnapshot {
        try self.prepareStateForConfiguration(configuration)

        let counters = try await self.fetchInterfaceCounters(configuration: configuration)
        defer { self.lastCounters = counters }

        guard let previous = self.lastCounters else {
            return TrafficSnapshot(up: 0, down: 0)
        }

        let interval = max(0.25, counters.sampledAt.timeIntervalSince(previous.sampledAt))
        let rxDelta = max(0, counters.rxBytes - previous.rxBytes)
        let txDelta = max(0, counters.txBytes - previous.txBytes)

        let down = Int64(Double(rxDelta) / interval)
        let up = Int64(Double(txDelta) / interval)
        return TrafficSnapshot(up: up, down: down)
    }

    private func prepareStateForConfiguration(_ configuration: OpenWrtTrafficConfiguration) throws {
        let fingerprint = [
            configuration.endpoint,
            configuration.interfaceName,
            configuration.username,
            configuration.password,
        ].joined(separator: "|")

        if self.lastConfigurationFingerprint != fingerprint {
            self.sessionState = nil
            self.lastCounters = nil
            self.lastConfigurationFingerprint = fingerprint
        }
    }

    private func fetchInterfaceCounters(configuration: OpenWrtTrafficConfiguration) async throws -> InterfaceCounters {
        let hadCachedSession = self.sessionState != nil
        do {
            return try await self.fetchInterfaceCountersOnce(configuration: configuration)
        } catch let error as OpenWrtTrafficServiceError where hadCachedSession && error.shouldRefreshSession {
            self.sessionState = nil
            return try await self.fetchInterfaceCountersOnce(configuration: configuration)
        }
    }

    private func fetchInterfaceCountersOnce(configuration: OpenWrtTrafficConfiguration) async throws -> InterfaceCounters {
        let sessionID = try await self.sessionID(configuration: configuration)
        if let counters = try await self.fetchInterfaceCountersViaNetworkDevice(
            configuration: configuration,
            sessionID: sessionID)
        {
            return counters
        }

        return try await self.fetchInterfaceCountersViaFileRead(
            configuration: configuration,
            sessionID: sessionID)
    }

    private func sessionID(configuration: OpenWrtTrafficConfiguration) async throws -> String {
        if let sessionState {
            return sessionState.id
        }

        let result = try await self.call(
            configuration: configuration,
            sessionID: String(repeating: "0", count: 32),
            object: "session",
            method: "login",
            arguments: [
                "username": configuration.username,
                "password": configuration.password,
            ])

        guard let payload = result as? [String: Any],
              let sessionID = payload["ubus_rpc_session"] as? String,
              !sessionID.isEmpty
        else {
            throw OpenWrtTrafficServiceError.missingSessionID
        }

        let sessionState = SessionState(id: sessionID)
        self.sessionState = sessionState
        return sessionState.id
    }

    private func fetchInterfaceCountersViaNetworkDevice(
        configuration: OpenWrtTrafficConfiguration,
        sessionID: String) async throws -> InterfaceCounters?
    {
        do {
            let result = try await self.call(
                configuration: configuration,
                sessionID: sessionID,
                object: "network.device",
                method: "status",
                arguments: ["name": configuration.interfaceName])

            guard let payload = result as? [String: Any] else {
                throw OpenWrtTrafficServiceError.invalidResponse
            }

            if let statistics = payload["statistics"] as? [String: Any],
               let rxBytes = Self.int64(from: statistics["rx_bytes"]),
               let txBytes = Self.int64(from: statistics["tx_bytes"])
            {
                return InterfaceCounters(rxBytes: rxBytes, txBytes: txBytes, sampledAt: Date())
            }

            if let rxBytes = Self.int64(from: payload["rx_bytes"]),
               let txBytes = Self.int64(from: payload["tx_bytes"])
            {
                return InterfaceCounters(rxBytes: rxBytes, txBytes: txBytes, sampledAt: Date())
            }

            return nil
        } catch let error as OpenWrtTrafficServiceError {
            switch error {
            case .permissionDenied, .rpcError, .missingStatistics:
                return nil
            default:
                throw error
            }
        }
    }

    private func fetchInterfaceCountersViaFileRead(
        configuration: OpenWrtTrafficConfiguration,
        sessionID: String) async throws -> InterfaceCounters
    {
        let basePath = "/sys/class/net/\(configuration.interfaceName)"
        let rxPayload = try await self.call(
            configuration: configuration,
            sessionID: sessionID,
            object: "file",
            method: "read",
            arguments: ["path": "\(basePath)/statistics/rx_bytes"])
        let txPayload = try await self.call(
            configuration: configuration,
            sessionID: sessionID,
            object: "file",
            method: "read",
            arguments: ["path": "\(basePath)/statistics/tx_bytes"])

        guard let rxData = (rxPayload as? [String: Any])?["data"] as? String,
              let txData = (txPayload as? [String: Any])?["data"] as? String,
              let rxBytes = Int64(rxData.trimmingCharacters(in: .whitespacesAndNewlines)),
              let txBytes = Int64(txData.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw OpenWrtTrafficServiceError.missingStatistics
        }

        return InterfaceCounters(rxBytes: rxBytes, txBytes: txBytes, sampledAt: Date())
    }

    private func call(
        configuration: OpenWrtTrafficConfiguration,
        sessionID: String,
        object: String,
        method: String,
        arguments: [String: Any]) async throws -> Any
    {
        let endpointURL = try self.ubusURL(from: configuration.endpoint)
        var request = URLRequest(url: endpointURL)
        request.httpMethod = HTTPMethod.post.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "call",
            "params": [sessionID, object, method, arguments],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenWrtTrafficServiceError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw OpenWrtTrafficServiceError.httpStatus(httpResponse.statusCode, message)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenWrtTrafficServiceError.invalidResponse
        }

        if let error = json["error"] as? [String: Any] {
            throw self.rpcError(from: error)
        }

        guard let result = json["result"] as? [Any],
              let status = result.first as? Int
        else {
            throw OpenWrtTrafficServiceError.invalidResponse
        }

        if status != 0 {
            if status == 6 {
                let message = result.count > 1
                    ? String(describing: result[1])
                    : self.rpcStatusDescription(status)
                throw OpenWrtTrafficServiceError.permissionDenied(message)
            }
            let message = result.count > 1 ? String(describing: result[1]) : self.rpcStatusDescription(status)
            throw OpenWrtTrafficServiceError.rpcError(message)
        }

        return result.count > 1 ? result[1] : [:]
    }

    private func ubusURL(from endpoint: String) throws -> URL {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenWrtTrafficServiceError.invalidEndpoint }

        let normalized = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: normalized),
              components.host?.isEmpty == false
        else {
            throw OpenWrtTrafficServiceError.invalidEndpoint
        }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty {
            components.path = "/ubus"
        } else if path != "ubus" {
            components.path = "/\(path)/ubus"
        }

        guard let url = components.url else {
            throw OpenWrtTrafficServiceError.invalidEndpoint
        }
        return url
    }

    private static func int64(from value: Any?) -> Int64? {
        switch value {
        case let value as Int64:
            value
        case let value as Int:
            Int64(value)
        case let value as Double:
            Int64(value)
        case let value as NSNumber:
            value.int64Value
        case let value as String:
            Int64(value)
        default:
            nil
        }
    }

    private func rpcError(from error: [String: Any]) -> OpenWrtTrafficServiceError {
        if let code = error["code"] as? Int, code == -32002 {
            return .permissionDenied("Permission denied (ubus HTTP ACL)")
        }
        return .rpcError(self.rpcErrorDescription(from: error))
    }

    private func rpcErrorDescription(from error: [String: Any]) -> String {
        if let message = error["message"] as? String, !message.isEmpty {
            return message
        }
        return String(describing: error)
    }

    private func rpcStatusDescription(_ status: Int) -> String {
        switch status {
        case 1:
            "Invalid command"
        case 2:
            "Invalid argument"
        case 3:
            "Method not found"
        case 4:
            "Object not found"
        case 5:
            "No data"
        case 6:
            "Permission denied (missing rpcd ACL for network.device/file)"
        case 7:
            "Request timed out"
        case 8:
            "Not supported"
        case 9:
            "Unknown error"
        case 10:
            "Connection failed"
        case 11:
            "Out of memory"
        case 12:
            "Parse error"
        case 13:
            "System error"
        default:
            "status=\(status)"
        }
    }
}
