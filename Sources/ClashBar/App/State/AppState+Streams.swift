import Foundation

@MainActor
extension AppState {
    enum StreamKind: CaseIterable, Hashable {
        case traffic
        case memory
        case connections
        case logs

        var key: String {
            switch self {
            case .traffic: "traffic"
            case .memory: "memory"
            case .connections: "connections"
            case .logs: "logs"
            }
        }

        var label: String {
            switch self {
            case .traffic: "app.stream.label.traffic"
            case .memory: "app.stream.label.memory"
            case .connections: "app.stream.label.connections"
            case .logs: "app.stream.label.logs"
            }
        }
    }

    func startStream(
        kind: StreamKind,
        preserveReconnectState: Bool = false,
        makeWebSocket: @escaping (MihomoAPIClient) throws -> URLSessionWebSocketTask,
        onPayload: @escaping (Data) -> Void)
    {
        self.cancelStream(kind, resetReconnectState: !preserveReconnectState)

        do {
            let client = try self.clientOrThrow()
            let ws = try makeWebSocket(client)
            self.setWebSocketTask(ws, for: kind)
            ws.resume()

            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.receiveLoop(
                    kind: kind,
                    onPayload: onPayload,
                    restart: { [weak self] in
                        self?.startStream(
                            kind: kind,
                            preserveReconnectState: true,
                            makeWebSocket: makeWebSocket,
                            onPayload: onPayload)
                    })
            }
            self.setReceiveTask(task, for: kind)
        } catch {
            self.appendLog(
                level: "error",
                message: self.tr("log.stream.start_failed", self.tr(kind.label), error.localizedDescription))
        }
    }

    func cancelStream(_ kind: StreamKind, resetReconnectState: Bool = true) {
        self.receiveTask(for: kind)?.cancel()
        self.webSocketTask(for: kind)?.cancel(with: .goingAway, reason: nil)
        self.setReceiveTask(nil, for: kind)
        self.setWebSocketTask(nil, for: kind)
        if kind == .connections {
            self.currentConnectionsStreamIntervalMilliseconds = nil
        }
        if kind == .traffic {
            self.resetPendingTrafficSnapshotState()
            self.stopTrafficWatchdog()
        }
        if resetReconnectState {
            self.resetStreamReconnectState(for: kind)
        }
    }

    private func receiveLoop(
        kind: StreamKind,
        onPayload: @escaping (Data) -> Void,
        restart: @escaping () -> Void) async
    {
        while !Task.isCancelled {
            guard let ws = self.webSocketTask(for: kind) else { return }

            let message: URLSessionWebSocketTask.Message
            do {
                message = try await ws.receive()
            } catch {
                if Task.isCancelled { return }
                let disconnectMessage = error.localizedDescription
                if self.shouldLogStreamDisconnect(kind: kind, message: disconnectMessage) {
                    self.appendLog(
                        level: "error",
                        message: self.tr("log.stream.disconnected", self.tr(kind.label), disconnectMessage))
                }
                self.webSocketTask(for: kind)?.cancel(with: .goingAway, reason: nil)
                self.setWebSocketTask(nil, for: kind)

                guard self.isRemoteSessionActive else { return }
                do {
                    try await Task.sleep(nanoseconds: self.nextReconnectDelayNanoseconds(for: kind))
                } catch {
                    return
                }
                if Task.isCancelled { return }
                guard self.isRemoteSessionActive else { return }
                restart()
                return
            }

            guard let payload = self.normalizedWebSocketPayload(from: message) else { continue }
            self.markStreamPayloadReceived(for: kind)
            onPayload(payload)
        }
    }

    func receiveTask(for kind: StreamKind) -> Task<Void, Never>? {
        self.streamReceiveTasks[kind]
    }

    func setReceiveTask(_ task: Task<Void, Never>?, for kind: StreamKind) {
        if let task {
            self.streamReceiveTasks[kind] = task
        } else {
            self.streamReceiveTasks.removeValue(forKey: kind)
        }
    }

    func webSocketTask(for kind: StreamKind) -> URLSessionWebSocketTask? {
        self.streamWebSocketTasks[kind]
    }

    func setWebSocketTask(_ task: URLSessionWebSocketTask?, for kind: StreamKind) {
        if let task {
            self.streamWebSocketTasks[kind] = task
        } else {
            self.streamWebSocketTasks.removeValue(forKey: kind)
        }
    }

    func startTrafficStream() {
        self.startStream(
            kind: .traffic,
            makeWebSocket: { try $0.makeTrafficWebSocketTask() },
            onPayload: { [weak self] payload in
                guard let self else { return }
                self.lastTrafficPayloadReceivedAt = Date()
                self.pendingTrafficPayload = payload
                self.flushPendingTrafficSnapshotIfNeeded()
            })
        self.lastTrafficPayloadReceivedAt = Date()
        self.startTrafficWatchdog()
    }

    func flushPendingTrafficSnapshotIfNeeded(immediately: Bool = false) {
        guard self.pendingTrafficPayload != nil else { return }
        if immediately {
            self.publishPendingTrafficSnapshot()
            return
        }
        self.schedulePendingTrafficSnapshotPublishIfNeeded()
    }

    func startMemoryStream() {
        self.startDecodableStream(
            kind: .memory,
            makeWebSocket: { try $0.makeMemoryWebSocketTask() },
            onDecoded: { [weak self] (snapshot: MemorySnapshot) in
                self?.memory = snapshot
            })
    }

    func startConnectionsStream(intervalMilliseconds: Int? = nil) {
        self.startDecodableStream(
            kind: .connections,
            makeWebSocket: { try $0.makeConnectionsWebSocketTask(interval: intervalMilliseconds) },
            onDecoded: { [weak self] (snapshot: ConnectionsSnapshot) in
                self?.applyConnectionsSnapshot(snapshot)
            })
        self.currentConnectionsStreamIntervalMilliseconds = intervalMilliseconds
    }

    func startLogsStream() {
        self.startStream(
            kind: .logs,
            makeWebSocket: { try $0.makeLogsWebSocketTask(level: nil) },
            onPayload: { [weak self] payload in
                guard let self else { return }
                if let line = self.decodeLogLinePayload(payload) {
                    self.appendMihomoLog(level: line.level, message: line.message)
                }
            })
    }

    private func schedulePendingTrafficSnapshotPublishIfNeeded() {
        guard self.trafficDecodeTask == nil else { return }

        let elapsed = Date().timeIntervalSince(self.lastTrafficDecodeAt)
        let publishInterval = Double(self.trafficPublishIntervalNanoseconds) / 1_000_000_000
        if elapsed >= publishInterval {
            self.publishPendingTrafficSnapshot()
            return
        }

        let remainingDelay = max(0.01, publishInterval - elapsed)
        let remainingNanoseconds = UInt64(remainingDelay * 1_000_000_000)
        self.trafficDecodeTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: remainingNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.publishPendingTrafficSnapshot()
        }
    }

    private func publishPendingTrafficSnapshot() {
        self.trafficDecodeTask?.cancel()
        self.trafficDecodeTask = nil

        guard let payload = self.pendingTrafficPayload else { return }
        self.pendingTrafficPayload = nil

        guard let snapshot = try? self.streamJSONDecoder.decode(TrafficSnapshot.self, from: payload) else {
            return
        }
        self.lastTrafficDecodeAt = Date()
        self.applyTrafficSnapshot(snapshot)

        if self.pendingTrafficPayload != nil {
            self.schedulePendingTrafficSnapshotPublishIfNeeded()
        }
    }

    private func applyTrafficSnapshot(_ snapshot: TrafficSnapshot) {
        self.traffic = snapshot
        guard self.isPanelPresented else {
            if !self.trafficHistoryUp.isEmpty || !self.trafficHistoryDown.isEmpty
                || self.displayUpTotal != 0 || self.displayDownTotal != 0 || self.lastTrafficSampleAt != nil
            {
                self.clearTrafficPresentationHistory()
            }
            return
        }
        self.appendTrafficHistory(up: snapshot.up, down: snapshot.down)
        self.updateTrafficTotals(from: snapshot)
    }

    private func resetPendingTrafficSnapshotState() {
        self.trafficDecodeTask?.cancel()
        self.trafficDecodeTask = nil
        self.pendingTrafficPayload = nil
        self.lastTrafficDecodeAt = .distantPast
        self.lastTrafficPayloadReceivedAt = nil
    }

    private func startTrafficWatchdog() {
        self.trafficWatchdogTask?.cancel()
        self.trafficWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: self?.trafficWatchdogIntervalNanoseconds ?? 2_000_000_000)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.restartTrafficStreamIfStalled()
            }
        }
    }

    private func stopTrafficWatchdog() {
        self.trafficWatchdogTask?.cancel()
        self.trafficWatchdogTask = nil
    }

    private func restartTrafficStreamIfStalled() {
        let policy = self.desiredDataAcquisitionPolicy(
            panelPresented: self.isPanelPresented,
            activeTab: self.activeMenuTab)
        guard self.isRemoteSessionActive, policy.enableTrafficStream else {
            self.stopTrafficWatchdog()
            return
        }
        guard self.webSocketTask(for: .traffic) != nil else { return }

        let lastPayloadAt = self.lastTrafficPayloadReceivedAt ?? .distantPast
        guard Date().timeIntervalSince(lastPayloadAt) > self.trafficStallTimeout else { return }

        self.startTrafficStream()
    }

    private func applyConnectionsSnapshot(_ snapshot: ConnectionsSnapshot) {
        let totalCount = snapshot.connections.count
        if self.connectionsCount != totalCount {
            self.connectionsCount = totalCount
        }

        let latestConnections = Array(snapshot.connections.prefix(self.maxRetainedConnections))
        if self.connections != latestConnections {
            self.connections = latestConnections
        }
    }

    private func resetStreamReconnectState(for kind: StreamKind) {
        self.streamReconnectAttempts.removeValue(forKey: kind.key)
        self.streamLastDisconnectLogAt.removeValue(forKey: kind.key)
        self.streamLastDisconnectLogMessage.removeValue(forKey: kind.key)
    }

    private func markStreamPayloadReceived(for kind: StreamKind) {
        self.streamReconnectAttempts[kind.key] = 0
    }

    private func nextReconnectDelayNanoseconds(for kind: StreamKind) -> UInt64 {
        let key = kind.key
        let attempt = max(0, self.streamReconnectAttempts[key] ?? 0)
        let cappedShift = min(attempt, 3)
        let seconds = min(8, 1 << cappedShift)
        self.streamReconnectAttempts[key] = min(attempt + 1, 8)

        let jitter = Double.random(in: 0.85...1.15)
        let base = UInt64(seconds) * self.streamReconnectBaseDelayNanoseconds
        let jittered = UInt64(Double(base) * jitter)
        return min(self.streamReconnectMaxDelayNanoseconds, max(self.streamReconnectBaseDelayNanoseconds, jittered))
    }

    private func shouldLogStreamDisconnect(kind: StreamKind, message: String) -> Bool {
        let key = kind.key
        let now = Date()
        let lastAt = self.streamLastDisconnectLogAt[key]
        let lastMessage = self.streamLastDisconnectLogMessage[key]

        let shouldEmit: Bool
        if let lastAt, let lastMessage {
            let withinThrottle = now.timeIntervalSince(lastAt) < self.streamDisconnectLogThrottleInterval
            shouldEmit = !(withinThrottle && lastMessage == message)
        } else {
            shouldEmit = true
        }

        if shouldEmit {
            self.streamLastDisconnectLogAt[key] = now
            self.streamLastDisconnectLogMessage[key] = message
        }
        return shouldEmit
    }
}
