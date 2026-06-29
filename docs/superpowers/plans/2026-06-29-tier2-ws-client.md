# Tier-2 WebSocket Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect AniCompanion to the OpenAB VTuber Adapter's Tier-2 WebSocket side-channel (`/v1/vtuber/ws`) so the character receives real-time agent state, structured emotions, and server-initiated notifications (ambient push).

**Architecture:** A new `AgentStateWSClient` actor manages a persistent `URLSessionWebSocketTask` connection to the adapter's WS endpoint. It receives four event types (`agent_state`, `emotion`, `notification`, `tool_status`) and dispatches them to `ConversationController` via a callback protocol. The controller maps `agent_state` to VRM animations, `emotion` to VRM expressions (bypassing inline-tag parsing), and `notification` to the existing proactive-message pipeline (TTS + lip sync). A new `@AppStorage` toggle + endpoint field in Settings lets the user enable Tier-2 independently of the Tier-1 chat backend.

**Tech Stack:** Swift 6 / macOS 15, URLSessionWebSocketTask, Swift concurrency (actor), existing CharacterControllerProtocol + ConversationController

## Global Constraints

- Swift 6.0, macOS 15.0+ deployment target
- Strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`)
- No SPM packages — URLSessionWebSocketTask is Foundation
- New Swift files go under `AniCompanion/` subtree (auto-included by `project.yml`'s glob)
- After adding files, run `xcodegen generate` from repo root to update the `.xcodeproj`

---

### Task 1: AgentStateWSClient — WS connection + event parsing

The core actor that connects to `/v1/vtuber/ws`, receives JSON frames, parses them into typed Swift events, and exposes them as an `AsyncStream`.

**Files:**
- Create: `AniCompanion/Services/AgentStateWSClient.swift`

**Interfaces:**
- Consumes: nothing (standalone)
- Produces:
  - `enum AgentStateEvent: Sendable` — `agentState(state: String, sessionId: String)`, `emotion(tag: String, intensity: Float)`, `notification(text: String, urgency: String)`, `toolStatus(name: String, status: String)`, `connected`, `disconnected`
  - `actor AgentStateWSClient` — `init(endpoint: String, token: String)`, `func connect()`, `func disconnect()`, `var events: AsyncStream<AgentStateEvent>`

- [ ] **Step 1: Create the event enum and actor skeleton**

```swift
// AniCompanion/Services/AgentStateWSClient.swift

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
        // Append /v1/vtuber/ws if not already in path
        if !components.path.hasSuffix("/v1/vtuber/ws") {
            components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            components.path = "/" + components.path + "/v1/vtuber/ws"
        }
        // ws:// or wss://
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
        Task {
            try? await Task.sleep(for: .seconds(5))
            if !isRunning {
                isRunning = false
                connect()
            }
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
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodegen generate && xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add AniCompanion/Services/AgentStateWSClient.swift
git commit -m "feat: add AgentStateWSClient for Tier-2 VTuber WS side-channel"
```

---

### Task 2: Wire AgentStateWSClient into ConversationController

Connect the WS client's event stream to the existing character controller and notification pipeline so events drive the avatar in real time.

**Files:**
- Modify: `AniCompanion/Pipeline/ConversationController.swift`

**Interfaces:**
- Consumes: `AgentStateWSClient.events: AsyncStream<AgentStateEvent>`, `CharacterControllerProtocol.setExpression()`, `CharacterControllerProtocol.playAnimation()`, `ConversationController.sendProactiveMessage(prompt:)`
- Produces: `ConversationController.agentStateClient: AgentStateWSClient?` (optional, set by AppState), `ConversationController.startAgentStateListener()`

- [ ] **Step 1: Add the client property and listener method**

Add these to `ConversationController` after the existing properties (around line 95):

```swift
    // In the properties section, after notificationTask:

    /// Tier-2 WebSocket client for agent-state push from the VTuber adapter.
    var agentStateClient: AgentStateWSClient?

    /// Task running the Tier-2 WS event listener.
    private var agentStateListenerTask: Task<Void, Never>?
```

Add this method after `startProactiveTimer()` (around line 343):

```swift
    // MARK: - Agent State (Tier-2 WS)

    /// Listen for Tier-2 WS events and drive character animation + proactive speech.
    func startAgentStateListener() {
        guard let client = agentStateClient else { return }
        agentStateListenerTask?.cancel()

        agentStateListenerTask = Task { [weak self] in
            await client.connect()

            for await event in await client.events {
                guard let self, !Task.isCancelled else { break }
                switch event {
                case .agentState(let state, _):
                    self.handleAgentState(state)
                case .emotion(let tag, _):
                    if let emotion = Emotion.from(tag: "[\(tag)]") {
                        self.charController?.setExpression(emotion, blendDuration: 0.3)
                    }
                case .notification(let text, let urgency):
                    self.handleAmbientNotification(text: text, urgency: urgency)
                case .toolStatus:
                    break // ponytail: display in UI when chat panel shows tool activity
                case .connected, .disconnected:
                    break
                }
            }
        }
    }

    private func handleAgentState(_ state: String) {
        switch state {
        case "thinking":
            charController?.playAnimation(named: "think")
        case "working":
            charController?.playAnimation(named: "talk_gesture")
        case "attention":
            charController?.playAnimation(named: "wave")
        case "idle":
            charController?.stopAnimation()
        case "error":
            charController?.setExpression(.surprised, blendDuration: 0.2)
        default:
            break
        }
    }

    private func handleAmbientNotification(text: String, urgency: String) {
        guard urgency == "high" || !isProcessing else { return }
        Task {
            await sendProactiveMessage(prompt: text)
        }
    }
```

- [ ] **Step 2: Clean up the listener on cancel**

In the existing `cancelInternal()` method (the one that cancels `proactiveTimer` around line 730-744), add cleanup for the agent state listener:

```swift
    // Add after the existing notificationTask cleanup:
    agentStateListenerTask?.cancel()
    agentStateListenerTask = nil
```

- [ ] **Step 3: Add `charController` convenience alias**

`ConversationController` already has a `characterController` property. The code above uses `charController` as a short alias. Add it near the existing `characterController` property if it doesn't already exist:

Check if `charController` is already used. If `characterController` is the existing name, change the code in Step 1 to use `characterController` instead. (Search for `charController` vs `characterController` in the file to see which is used.)

- [ ] **Step 4: Verify it compiles**

Run: `xcodegen generate && xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add AniCompanion/Pipeline/ConversationController.swift
git commit -m "feat: wire Tier-2 WS events to character animation and proactive speech"
```

---

### Task 3: Settings UI + AppState wiring

Add a toggle and endpoint field in Settings so the user can enable Tier-2 and point it at their VTuber adapter. Wire `AppState` to create and pass the `AgentStateWSClient` into `ConversationController`.

**Files:**
- Modify: `AniCompanion/App/AppState.swift`
- Modify: `AniCompanion/Views/SettingsView.swift`

**Interfaces:**
- Consumes: `AgentStateWSClient(endpoint:token:)`, `ConversationController.agentStateClient`, `ConversationController.startAgentStateListener()`
- Produces: `AppState.tier2Enabled: Bool` (`@AppStorage`), `AppState.tier2Endpoint: String` (`@AppStorage`)

- [ ] **Step 1: Add @AppStorage properties to AppState**

In `AppState.swift`, add after the existing `@AppStorage` block (around line 36):

```swift
    /// Whether the Tier-2 VTuber WS side-channel is enabled. Connects to the OpenAB
    /// VTuber Adapter's /v1/vtuber/ws for agent-state push, structured emotions,
    /// and ambient notifications.
    @AppStorage("tier2_ws_enabled") var tier2Enabled: Bool = false

    /// Base URL of the VTuber adapter for Tier-2 WS (e.g. "http://127.0.0.1:9100").
    /// The client appends /v1/vtuber/ws and upgrades to ws://.
    @AppStorage("tier2_ws_endpoint") var tier2Endpoint: String = "http://127.0.0.1:9100"
```

- [ ] **Step 2: Create and wire the WS client in initializeServices()**

In `AppState.initializeServices()`, after `conversationController = controller` (around line 133), add:

```swift
        // Tier-2: agent-state WS side-channel (optional).
        if tier2Enabled {
            let backend = ChatBackend.current
            let wsClient = AgentStateWSClient(
                endpoint: tier2Endpoint,
                token: backend.savedAPIKey()
            )
            controller.agentStateClient = wsClient
            controller.startAgentStateListener()
        }
```

- [ ] **Step 3: Add Tier-2 section to SettingsView**

In `SettingsView.swift`, add local `@State` properties after the existing ones (around line 25):

```swift
    @State private var tier2Enabled: Bool = false
    @State private var tier2Endpoint: String = "http://127.0.0.1:9100"
```

Add a new section after the Voice section (Section 2, around line 158). Insert before the Language section:

```swift
                    // MARK: Section 3: Agent State (Tier-2)

                    SettingsSection(title: "Agent State", icon: "antenna.radiowaves.left.and.right") {
                        VStack(alignment: .leading, spacing: 14) {
                            Toggle("Enable Tier-2 WS", isOn: $tier2Enabled)
                                .toggleStyle(.switch)

                            if tier2Enabled {
                                SettingsField(label: "Adapter Endpoint") {
                                    TextField("http://127.0.0.1:9100", text: $tier2Endpoint)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }

                            Text("Connects to the OpenAB VTuber Adapter for real-time agent state, emotions, and ambient notifications.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
```

In `loadSettings()`, add:

```swift
        tier2Enabled = appState.tier2Enabled
        tier2Endpoint = appState.tier2Endpoint
```

In `saveSettings()`, add before `appState.reinitializeServices()`:

```swift
        appState.tier2Enabled = tier2Enabled
        appState.tier2Endpoint = tier2Endpoint
```

- [ ] **Step 4: Verify it compiles**

Run: `xcodegen generate && xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add AniCompanion/App/AppState.swift AniCompanion/Views/SettingsView.swift
git commit -m "feat: add Tier-2 WS settings (toggle + endpoint) and wire into AppState"
```

---

### Task 4: Keepalive + reconnect hardening

Add a periodic ping to keep the WS alive and handle macOS App Nap. Use `DispatchSourceTimer` with `.strict` (same pattern as the proactive timer) instead of `Task.sleep` which App Nap can suspend.

**Files:**
- Modify: `AniCompanion/Services/AgentStateWSClient.swift`

**Interfaces:**
- Consumes: existing `AgentStateWSClient`
- Produces: hardened reconnect + 30s keepalive ping

- [ ] **Step 1: Add keepalive timer and improve reconnect**

Replace the `scheduleReconnect()` method and add a keepalive timer. In `AgentStateWSClient`, add a `pingTimer` property and update `connect()`/`disconnect()`:

Add property:

```swift
    private var pingInterval: TimeInterval = 30
```

Update `connect()` — after `continuation?.yield(.connected)` and `receiveLoop()`, add:

```swift
        startPingLoop()
```

Add the ping loop method:

```swift
    private func startPingLoop() {
        Task {
            while isRunning {
                try? await Task.sleep(for: .seconds(pingInterval))
                guard isRunning else { break }
                sendPing()
            }
        }
    }
```

Update `scheduleReconnect()` to use exponential backoff capped at 30s:

```swift
    private var reconnectAttempts = 0

    private func scheduleReconnect() {
        let delay = min(Double(1 << reconnectAttempts), 30.0)
        reconnectAttempts += 1
        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !isRunning else { return }
            connect()
        }
    }
```

Reset `reconnectAttempts = 0` inside `connect()` after the connection succeeds (after `wsTask.resume()`).

- [ ] **Step 2: Subscribe to relevant events on connect**

In `connect()`, after `receiveLoop()`, add:

```swift
        sendSubscribe(events: ["agent_state", "emotion", "notification"])
```

This tells the adapter to skip `tool_status` by default (less noise). The subscribe can be made configurable later if needed.

- [ ] **Step 3: Verify it compiles**

Run: `xcodegen generate && xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add AniCompanion/Services/AgentStateWSClient.swift
git commit -m "feat: add keepalive ping and exponential backoff reconnect to Tier-2 WS"
```

---

### Task 5: Disconnect cleanup in AppState.reinitializeServices()

When the user saves settings, `reinitializeServices()` tears down everything. It must also disconnect the Tier-2 WS client to avoid orphaned connections.

**Files:**
- Modify: `AniCompanion/App/AppState.swift`

**Interfaces:**
- Consumes: `AgentStateWSClient.disconnect()`, `ConversationController.agentStateClient`
- Produces: clean teardown on reinitialize

- [ ] **Step 1: Disconnect WS client before reinitialize**

In `reinitializeServices()`, after `conversationController?.cancel()` and before `chatTransport?.disconnect()`, add:

```swift
        // Tear down Tier-2 WS.
        if let wsClient = conversationController?.agentStateClient {
            Task { await wsClient.disconnect() }
        }
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add AniCompanion/App/AppState.swift
git commit -m "fix: disconnect Tier-2 WS client on service reinitialize"
```
