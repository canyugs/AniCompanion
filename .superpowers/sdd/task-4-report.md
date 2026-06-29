# Task 4 Report: Keepalive + Reconnect Hardening

## Status: COMPLETE

## Changes Made

**File:** `AniCompanion/Services/AgentStateWSClient.swift`

### 1. New Properties
Added to the actor:
```swift
private var pingInterval: TimeInterval = 30
private var reconnectAttempts = 0
```

### 2. Updated `connect()`
After `wsTask.resume()`:
- Resets `reconnectAttempts = 0` on successful connection
- Calls `startPingLoop()` after `receiveLoop()`
- Calls `sendSubscribe(events: ["agent_state", "emotion", "notification"])` to filter out `tool_status` noise

### 3. Updated `scheduleReconnect()`
Replaced fixed 5s delay with exponential backoff capped at 30s, while preserving the existing `generation` counter check:
```swift
let delay = min(Double(1 << reconnectAttempts), 30.0)
reconnectAttempts += 1
let gen = generation
// ... Task.sleep(delay), guard generation == gen
```
Backoff sequence: 1s → 2s → 4s → 8s → 16s → 30s (capped).

### 4. Added `startPingLoop()`
Uses `Task.sleep` to send a ping every 30 seconds while `isRunning`:
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

## Build Result
`BUILD SUCCEEDED`

## Commit
`dc62178` — `feat: add keepalive ping and exponential backoff reconnect to Tier-2 WS`

## Notes
- The `generation` guard in `scheduleReconnect()` is preserved: when `disconnect()` is called, it bumps `generation`, which causes any pending reconnect Task to bail out before calling `connect()`.
- `reconnectAttempts` resets to 0 on each successful connect, so backoff restarts fresh after recovery.
- `startPingLoop()` exits cleanly when `isRunning` becomes false (set by `disconnect()` or `handleReceive` failure), avoiding ghost ping Tasks.
