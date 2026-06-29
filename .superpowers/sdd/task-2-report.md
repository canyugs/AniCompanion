# Task 2 Report: Wire AgentStateWSClient into ConversationController

## Status: COMPLETE

## Changes Made

**File modified:** `AniCompanion/Pipeline/ConversationController.swift`

### Properties added (after `notificationTask`, ~line 95)

- `var agentStateClient: AgentStateWSClient?` — optional, set by AppState to inject the Tier-2 WS client
- `private var agentStateListenerTask: Task<Void, Never>?` — holds the long-lived listener task for cleanup

### Methods added (after `resetProactiveTimer()`)

- `startAgentStateListener()` — public entry point; cancels any prior listener, calls `client.connect()`, then iterates `client.events`. Handles all `AgentStateEvent` cases.
- `handleAgentState(_ state: String)` — private; maps agent state strings to animation clips:
  - `"thinking"` → `playAnimation(named: "think")`
  - `"working"` → `playAnimation(named: "talk_gesture")`
  - `"attention"` → `playAnimation(named: "wave")`
  - `"idle"` → `stopAnimation()`
  - `"error"` → `setExpression(.surprised, blendDuration: 0.2)`
- `handleAmbientNotification(text:urgency:)` — private; calls `sendProactiveMessage(prompt:)` when urgency is `"high"` or the controller is not already processing.

### Cleanup added (`cancelInternal()`)

Added `agentStateListenerTask?.cancel()` and `agentStateListenerTask = nil` after the existing `notificationTask` cleanup, so the Tier-2 listener is torn down whenever the pipeline is cancelled.

## Concurrency Notes

- `agentStateListenerTask` is a `Task` on `@MainActor` (ConversationController is `@MainActor`).
- Inside the task, `await client.connect()` and `await client.events` correctly cross the actor boundary to the `AgentStateWSClient` actor.
- `self.handleAgentState(_:)` and `self.characterController?.*` calls are safe because the task captures `[weak self]` and the handlers are all `@MainActor`.

## Build Result

`** BUILD SUCCEEDED **` — no warnings or errors related to the new code.

## Commit

`d566367 feat: wire Tier-2 WS events to character animation and proactive speech`
