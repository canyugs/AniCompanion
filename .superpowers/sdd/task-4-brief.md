# Task 4: Keepalive + reconnect hardening

Add a periodic ping to keep the WS alive and handle macOS App Nap. Use `DispatchSourceTimer` with `.strict` (same pattern as the proactive timer) instead of `Task.sleep` which App Nap can suspend.

## Global Constraints

- Swift 6.0, macOS 15.0+ deployment target
- Strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`)
- No SPM packages — URLSessionWebSocketTask is Foundation
- New Swift files go under `AniCompanion/` subtree (auto-included by `project.yml`'s glob)
- After adding files, run `xcodegen generate` from repo root to update the `.xcodeproj`

## Files

- Modify: `AniCompanion/Services/AgentStateWSClient.swift`

## Interfaces

- Consumes: existing `AgentStateWSClient`
- Produces: hardened reconnect + 30s keepalive ping

## Steps

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
