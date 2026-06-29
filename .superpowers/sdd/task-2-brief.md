# Task 2: Wire AgentStateWSClient into ConversationController

Connect the WS client's event stream to the existing character controller and notification pipeline so events drive the avatar in real time.

## Global Constraints

- Swift 6.0, macOS 15.0+ deployment target
- Strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`)
- No SPM packages — URLSessionWebSocketTask is Foundation
- New Swift files go under `AniCompanion/` subtree (auto-included by `project.yml`'s glob)
- After adding files, run `xcodegen generate` from repo root to update the `.xcodeproj`

## Files

- Modify: `AniCompanion/Pipeline/ConversationController.swift`

## Interfaces

- Consumes: `AgentStateWSClient.events: AsyncStream<AgentStateEvent>`, `CharacterControllerProtocol.setExpression()`, `CharacterControllerProtocol.playAnimation()`, `ConversationController.sendProactiveMessage(prompt:)`
- Produces: `ConversationController.agentStateClient: AgentStateWSClient?` (optional, set by AppState), `ConversationController.startAgentStateListener()`

## Steps

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
                        self.characterController?.setExpression(emotion, blendDuration: 0.3)
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
            characterController?.playAnimation(named: "think")
        case "working":
            characterController?.playAnimation(named: "talk_gesture")
        case "attention":
            characterController?.playAnimation(named: "wave")
        case "idle":
            characterController?.stopAnimation()
        case "error":
            characterController?.setExpression(.surprised, blendDuration: 0.2)
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

**Note:** The property name in ConversationController is `characterController` (not `charController`). The code above uses the correct name.

- [ ] **Step 2: Clean up the listener on cancel**

In the existing `cancelInternal()` method (the one that cancels `proactiveTimer` around line 730-744), add cleanup for the agent state listener:

```swift
    // Add after the existing notificationTask cleanup:
    agentStateListenerTask?.cancel()
    agentStateListenerTask = nil
```

- [ ] **Step 3: Add `charController` convenience alias**

`ConversationController` already has a `characterController` property. The code above uses `characterController` as the actual property name. If you prefer to use a shorter alias elsewhere, that can be added near the existing `characterController` property, but the primary property is `characterController`.

- [ ] **Step 4: Verify it compiles**

Run: `xcodegen generate && xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add AniCompanion/Pipeline/ConversationController.swift
git commit -m "feat: wire Tier-2 WS events to character animation and proactive speech"
```
