import Foundation

// MARK: - Events

enum AgentStateEvent: Sendable {
    case agentState(state: String, sessionId: String)
    case emotion(tag: String, intensity: Float)
    case notification(text: String, urgency: String)
    case toolStatus(name: String, status: String)
    case connected
    case disconnected
}

// MARK: - AgentStateWSClient

actor AgentStateWSClient {

    private let endpoint: String
    private let token: String
    private var task: URLSessionWebSocketTask?
    private var continuation: AsyncStream<AgentStateEvent>.Continuation?
    private var isRunning = false
    private var generation: Int = 0

    let events: AsyncStream<AgentStateEvent>

    init(endpoint: String, token: String) {
        self.endpoint = endpoint
        self.token = token

        var cont: AsyncStream<AgentStateEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    func connect() {
        guard !isRunning else { return }
        isRunning = true

        guard var components = URLComponents(string: endpoint) else {
            continuation?.yield(.disconnected)
            return
        }
        if !components.path.hasSuffix("/v1/vtuber/ws") {
            components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            components.path = "/" + components.path + "/v1/vtuber/ws"
        }
        if components.scheme == "http" { components.scheme = "ws" }
        if components.scheme == "https" { components.scheme = "wss" }

        guard let url = components.url else {
            continuation?.yield(.disconnected)
            return
        }

        var request = URLRequest(url: url)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let session = URLSession(configuration: .default)
        let wsTask = session.webSocketTask(with: request)
        self.task = wsTask
        wsTask.resume()

        continuation?.yield(.connected)
        receiveLoop()
    }

    func disconnect() {
        isRunning = false
        generation &+= 1
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        continuation?.yield(.disconnected)
    }

    // MARK: - Receive Loop

    private func receiveLoop() {
        guard let task, isRunning else { return }
        task.receive { [weak self] result in
            Task { await self?.handleReceive(result) }
        }
    }

    private func handleReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        switch result {
        case .success(let message):
            if case .string(let text) = message {
                parseFrame(text)
            }
            receiveLoop()
        case .failure:
            isRunning = false
            continuation?.yield(.disconnected)
            scheduleReconnect()
        }
    }

    // MARK: - Frame Parsing

    private func parseFrame(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "agent_state":
            let state = json["state"] as? String ?? "idle"
            let sessionId = json["session_id"] as? String ?? ""
            continuation?.yield(.agentState(state: state, sessionId: sessionId))

        case "emotion":
            let tag = json["tag"] as? String ?? "neutral"
            let intensity = (json["intensity"] as? NSNumber)?.floatValue ?? 1.0
            continuation?.yield(.emotion(tag: tag, intensity: intensity))

        case "notification":
            let text = json["text"] as? String ?? ""
            let urgency = json["urgency"] as? String ?? "normal"
            continuation?.yield(.notification(text: text, urgency: urgency))

        case "tool_status":
            let name = json["tool_name"] as? String ?? ""
            let status = json["status"] as? String ?? ""
            continuation?.yield(.toolStatus(name: name, status: status))

        case "pong":
            break

        default:
            break
        }
    }

    // MARK: - Reconnect

    private func scheduleReconnect() {
        let gen = generation
        Task {
            try? await Task.sleep(for: .seconds(5))
            guard self.generation == gen else { return }
            connect()
        }
    }

    // MARK: - Keepalive

    func sendPing() {
        let ping = #"{"type":"ping"}"#
        task?.send(.string(ping)) { _ in }
    }

    func sendSubscribe(events: [String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": "subscribe", "events": events]),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }
}
